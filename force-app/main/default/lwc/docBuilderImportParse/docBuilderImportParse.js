/**
 * Reads a template made elsewhere (a Word .docx file, HTML, plain text or a DocBuilder export) into a neutral
 * model the import wizard can map to Salesforce fields and turn into DocBuilder blocks.
 *
 * Merge fields in the common styles are recognised, so templates from other tools carry over:
 *   {{Field}}  {!Field}  «Field»  <<Field>>  [[Field]]  {Field.Path}   and Word MERGEFIELD fields
 *   Repeating rows: {{#each List}} / {{/each}}, {#List} / {/List}, TableStart:List / TableEnd:List
 * Each merge field is replaced in the content by a placeholder (\u0002n\u0003) pointing at model.tokens[n],
 * so it stays in one piece whatever formatting surrounds it.
 *
 * Word files are unzipped in the browser with the built-in DecompressionStream; nothing is uploaded.
 */

const W = 'http://schemas.openxmlformats.org/wordprocessingml/2006/main';
const R = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships';
const OPEN = '\u0002';
const CLOSE = '\u0003';

// Built with RegExp strings: the LWC compiler rejects some regex literals that contain a slash in a character class.
const TOKEN_PATTERN = new RegExp(
    [
        '\\{\\{\\s*([^{}]+?)\\s*\\}\\}', // {{Field}}
        '\\{!\\s*([^{}]+?)\\s*\\}', // {!Field}
        '«\\s*([^«»]+?)\\s*»', // «Field»
        '<<\\s*([^<>]+?)\\s*>>', // <<Field>>
        '\\[\\[\\s*([^\\[\\]]+?)\\s*\\]\\]', // [[Field]]
        '\\{\\s*([#/]?[A-Za-z_][\\w.]*)\\s*\\}' // {Field.Path}, {#List}, {/List}
    ].join('|'),
    'g'
);
const LIST_START = new RegExp('^(?:#\\s*(?:each\\s+)?|each\\s+|foreach\\s+|TableStart\\s*:\\s*|BeginGroup\\s*:\\s*)(.+)$', 'i');
const LIST_END = new RegExp('^(?:/.*|end\\s*each.*|TableEnd\\s*:.*|EndGroup\\s*:.*)$', 'i');
const MERGEFIELD = new RegExp('^\\s*MERGEFIELD\\s+(?:"([^"]+)"|(\\S+))', 'i');
const PAGE_FIELD = new RegExp('^\\s*(PAGE|NUMPAGES|SECTIONPAGES)\\b', 'i');
const LOOKS_LIKE_HTML = new RegExp('<\\s*(p|div|table|h[1-6]|br|span|ul|ol|li|strong|b|em|i|u|body|html)\\b', 'i');
const PLACEHOLDER = new RegExp(OPEN + '(\\d+)' + CLOSE, 'g');

export { OPEN, CLOSE, PLACEHOLDER };

// ---------- Small helpers ----------

export function simplify(value) {
    let s = String(value || '').trim();
    if (/^[A-Za-z][A-Za-z0-9]*__[A-Za-z].*__[a-zA-Z]+$/.test(s)) {
        s = s.substring(s.indexOf('__') + 2);
    }
    s = s.replace(/__(c|r|e|mdt)$/, '');
    return s.toLowerCase().replace(/[^a-z0-9]/g, '');
}

export function escapeHtml(text) {
    return String(text).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

function newModel(source) {
    return { source, items: [], tokens: [], header: '', footer: '', pageNumbers: false, images: 0, notes: [] };
}

function classify(name) {
    const start = LIST_START.exec(name);
    if (start) {
        return { kind: 'listStart', listName: start[1].trim() };
    }
    if (LIST_END.test(name)) {
        return { kind: 'listEnd' };
    }
    return { kind: 'field' };
}

function addToken(model, raw, name) {
    const clean = name.trim();
    model.tokens.push({ raw, name: clean, ...classify(clean) });
    return model.tokens.length - 1;
}

/** Merge fields in a piece of text, in order: [{ start, end, raw, name }]. */
function findTokens(text) {
    const found = [];
    TOKEN_PATTERN.lastIndex = 0;
    let m;
    while ((m = TOKEN_PATTERN.exec(text)) !== null) {
        const name = m.slice(1).find((g) => g !== undefined);
        found.push({ start: m.index, end: m.index + m[0].length, raw: m[0], name });
    }
    return found;
}

function fmtKey(f) {
    return f ? (f.b ? 'b' : '') + (f.i ? 'i' : '') + (f.u ? 'u' : '') : '';
}

function wrap(html, f) {
    let out = html;
    if (f && f.u) {
        out = '<u>' + out + '</u>';
    }
    if (f && f.i) {
        out = '<em>' + out + '</em>';
    }
    if (f && f.b) {
        out = '<strong>' + out + '</strong>';
    }
    return out;
}

/**
 * Turns formatted pieces of one paragraph into { html, text, formatted }. Merge fields become placeholders and
 * take the formatting of their first character, so a field split over several Word runs stays whole.
 */
function segmentsToContent(model, segments) {
    const full = segments.map((s) => s.text).join('');
    const formats = [];
    segments.forEach((s) => {
        for (let k = 0; k < s.text.length; k++) {
            formats.push(s.fmt);
        }
    });
    const tokens = findTokens(full);
    let html = '';
    let text = '';
    let buffer = '';
    let current = null;
    let formatted = false;
    const flush = () => {
        if (buffer) {
            html += wrap(buffer, current);
            buffer = '';
        }
    };
    const emit = (piece, htmlPiece, f) => {
        if (fmtKey(f) !== fmtKey(current)) {
            flush();
            current = f;
        }
        if (fmtKey(f)) {
            formatted = true;
        }
        buffer += htmlPiece;
        text += piece;
    };
    let i = 0;
    for (const t of tokens) {
        for (; i < t.start; i++) {
            const ch = full[i];
            emit(ch, ch === '\n' ? '<br/>' : escapeHtml(ch), formats[i]);
        }
        const placeholder = OPEN + addToken(model, t.raw, t.name) + CLOSE;
        emit(placeholder, placeholder, formats[t.start]);
        i = t.end;
    }
    for (; i < full.length; i++) {
        const ch = full[i];
        emit(ch, ch === '\n' ? '<br/>' : escapeHtml(ch), formats[i]);
    }
    flush();
    return { html, text, formatted };
}

// ---------- Zip (for .docx) ----------

const OLD_BROWSER = "This browser can't open Word files here. Use a current Chrome, Edge, Firefox or Safari, or save the document as a Web Page (.htm) and import that.";

async function inflate(bytes) {
    let decompressor;
    try {
        // 'deflate-raw' needs Chrome or Edge 103+, Firefox 113+ or Safari 16.4+.
        decompressor = new DecompressionStream('deflate-raw');
    } catch (e) {
        throw new Error(OLD_BROWSER);
    }
    const stream = new Blob([bytes]).stream().pipeThrough(decompressor);
    return new Uint8Array(await new Response(stream).arrayBuffer());
}

async function readZip(buffer) {
    const view = new DataView(buffer);
    const bytes = new Uint8Array(buffer);
    let end = -1;
    for (let p = buffer.byteLength - 22; p >= Math.max(0, buffer.byteLength - 65557); p--) {
        if (view.getUint32(p, true) === 0x06054b50) {
            end = p;
            break;
        }
    }
    if (end < 0) {
        throw new Error('This file is not a Word document (.docx). Older .doc files must be saved as .docx first.');
    }
    const count = view.getUint16(end + 10, true);
    let p = view.getUint32(end + 16, true);
    const entries = {};
    for (let n = 0; n < count; n++) {
        if (view.getUint32(p, true) !== 0x02014b50) {
            break;
        }
        const method = view.getUint16(p + 10, true);
        const size = view.getUint32(p + 20, true);
        const nameLength = view.getUint16(p + 28, true);
        const extraLength = view.getUint16(p + 30, true);
        const commentLength = view.getUint16(p + 32, true);
        const offset = view.getUint32(p + 42, true);
        const name = new TextDecoder().decode(bytes.subarray(p + 46, p + 46 + nameLength));
        entries[name] = { method, size, offset };
        p += 46 + nameLength + extraLength + commentLength;
    }
    return {
        has: (name) => !!entries[name],
        async text(name) {
            const e = entries[name];
            if (!e) {
                return null;
            }
            const start = e.offset + 30 + view.getUint16(e.offset + 26, true) + view.getUint16(e.offset + 28, true);
            const data = bytes.subarray(start, start + e.size);
            const raw = e.method === 0 ? data : await inflate(data);
            return new TextDecoder('utf-8').decode(raw);
        }
    };
}

// ---------- Word ----------

function attr(el, name) {
    if (!el) {
        return null;
    }
    const v = el.getAttributeNS(W, name);
    return v !== null && v !== '' ? v : el.getAttribute('w:' + name);
}

function child(el, name) {
    if (!el) {
        return null;
    }
    for (const c of el.childNodes) {
        if (c.nodeType === 1 && c.localName === name) {
            return c;
        }
    }
    return null;
}

function children(el, name) {
    const out = [];
    if (el) {
        for (const c of el.childNodes) {
            if (c.nodeType === 1 && (!name || c.localName === name)) {
                out.push(c);
            }
        }
    }
    return out;
}

function on(el) {
    if (!el) {
        return false;
    }
    const v = attr(el, 'val');
    return v === null || !['0', 'false', 'none'].includes(String(v).toLowerCase());
}

function parseXml(text) {
    return text ? new DOMParser().parseFromString(text, 'application/xml') : null;
}

class WordReader {
    constructor(model) {
        this.model = model;
        this.headingStyles = {};
        this.listFormats = {};
    }

    readStyles(doc) {
        if (!doc) {
            return;
        }
        for (const style of doc.getElementsByTagNameNS(W, 'style')) {
            const id = attr(style, 'styleId');
            const name = (attr(child(style, 'name'), 'val') || '').toLowerCase();
            const m = /^heading\s*(\d)/.exec(name);
            if (m) {
                this.headingStyles[id] = Math.min(3, Number(m[1]));
            } else if (name === 'title') {
                this.headingStyles[id] = 1;
            } else if (name === 'subtitle') {
                this.headingStyles[id] = 2;
            }
        }
    }

    readNumbering(doc) {
        if (!doc) {
            return;
        }
        const abstractFormats = {};
        for (const a of doc.getElementsByTagNameNS(W, 'abstractNum')) {
            const level = children(a, 'lvl').find((l) => attr(l, 'ilvl') === '0') || child(a, 'lvl');
            abstractFormats[attr(a, 'abstractNumId')] = attr(child(level, 'numFmt'), 'val') || 'bullet';
        }
        for (const n of doc.getElementsByTagNameNS(W, 'num')) {
            const fmt = abstractFormats[attr(child(n, 'abstractNumId'), 'val')];
            this.listFormats[attr(n, 'numId')] = fmt === 'bullet' || fmt === 'none' ? 'ul' : 'ol';
        }
    }

    /** The pieces of one paragraph: [{ text, fmt }], following Word's complex fields (begin, instruction, result, end). */
    paragraphSegments(p, state) {
        const segments = [];
        const fields = [];
        const push = (text, fmt) => {
            const field = fields[fields.length - 1];
            if (field && (field.phase === 'instr' || field.hide)) {
                return;
            }
            segments.push({ text, fmt });
        };
        const startResult = (field, fmt) => {
            const merge = MERGEFIELD.exec(field.instr);
            if (merge) {
                const name = (merge[1] || merge[2]).trim();
                segments.push({ text: '«' + name + '»', fmt });
                field.hide = true;
            } else if (PAGE_FIELD.test(field.instr)) {
                state.pageField = true;
                field.hide = true;
            }
            field.done = true;
        };
        const walk = (el, fmt) => {
            for (const c of children(el)) {
                switch (c.localName) {
                    case 'pPr':
                    case 'rPr':
                    case 'del':
                    case 'proofErr':
                    case 'bookmarkStart':
                    case 'bookmarkEnd':
                        break;
                    case 'r': {
                        const rPr = child(c, 'rPr');
                        const runFmt = {
                            b: on(child(rPr, 'b')),
                            i: on(child(rPr, 'i')),
                            u: !!child(rPr, 'u') && attr(child(rPr, 'u'), 'val') !== 'none'
                        };
                        for (const part of children(c)) {
                            const name = part.localName;
                            if (name === 't') {
                                push(part.textContent, runFmt);
                            } else if (name === 'tab') {
                                push(' ', runFmt);
                            } else if (name === 'br' || name === 'cr') {
                                if (attr(part, 'type') === 'page') {
                                    state.pageBreakAfter = true;
                                } else {
                                    push('\n', runFmt);
                                }
                            } else if (name === 'fldChar') {
                                const type = attr(part, 'fldCharType');
                                if (type === 'begin') {
                                    fields.push({ instr: '', phase: 'instr' });
                                } else if (type === 'separate' && fields.length) {
                                    const field = fields[fields.length - 1];
                                    field.phase = 'result';
                                    startResult(field, runFmt);
                                } else if (type === 'end' && fields.length) {
                                    const field = fields.pop();
                                    if (!field.done) {
                                        field.phase = 'result';
                                        startResult(field, runFmt);
                                    }
                                }
                            } else if (name === 'instrText') {
                                if (fields.length) {
                                    fields[fields.length - 1].instr += part.textContent;
                                }
                            } else if (name === 'drawing' || name === 'pict' || name === 'object') {
                                this.model.images++;
                            }
                        }
                        break;
                    }
                    case 'fldSimple': {
                        const field = { instr: attr(c, 'instr') || '', phase: 'result' };
                        fields.push(field);
                        startResult(field, fmt);
                        if (!field.hide) {
                            walk(c, fmt);
                        }
                        fields.pop();
                        break;
                    }
                    default:
                        // Hyperlinks, tracked insertions, smart tags and content controls hold runs of their own.
                        walk(c, fmt);
                }
            }
        };
        walk(p, null);
        return segments;
    }

    paragraph(p, state) {
        const pPr = child(p, 'pPr');
        const styleId = attr(child(pPr, 'pStyle'), 'val');
        const align = attr(child(pPr, 'jc'), 'val');
        const numPr = child(pPr, 'numPr');
        const numId = numPr ? attr(child(numPr, 'numId'), 'val') : null;
        const content = segmentsToContent(this.model, this.paragraphSegments(p, state));
        return {
            kind: this.headingStyles[styleId] ? 'heading' : 'para',
            level: this.headingStyles[styleId] || 0,
            align: align === 'center' ? 'center' : align === 'right' || align === 'end' ? 'right' : align === 'both' ? 'justify' : '',
            list: numId && numId !== '0' ? this.listFormats[numId] || 'ul' : null,
            pageBreakBefore: on(child(pPr, 'pageBreakBefore')),
            ...content
        };
    }

    table(tbl) {
        const rows = [];
        for (const tr of children(tbl, 'tr')) {
            const cells = [];
            for (const tc of children(tr, 'tc')) {
                const parts = [];
                const collect = (el) => {
                    for (const c of children(el)) {
                        if (c.localName === 'p') {
                            parts.push(this.paragraph(c, {}));
                        } else if (c.localName === 'tbl') {
                            // A table inside a cell is flattened into its text.
                            for (const r of children(c, 'tr')) {
                                for (const cell of children(r, 'tc')) {
                                    collect(cell);
                                }
                            }
                        } else if (c.localName === 'sdt') {
                            collect(child(c, 'sdtContent'));
                        }
                    }
                };
                collect(tc);
                const nonEmpty = parts.filter((x) => x.text.trim());
                cells.push({
                    html: nonEmpty.map((x) => x.html).join('<br/>'),
                    text: nonEmpty.map((x) => x.text).join('\n'),
                    formatted: nonEmpty.some((x) => x.formatted),
                    align: (nonEmpty[0] && nonEmpty[0].align) || ''
                });
            }
            rows.push(cells);
        }
        return { kind: 'table', rows };
    }

    body(container, items) {
        for (const el of children(container)) {
            if (el.localName === 'p') {
                const state = {};
                const item = this.paragraph(el, state);
                if (item.pageBreakBefore) {
                    items.push({ kind: 'pagebreak' });
                }
                items.push(item);
                if (state.pageBreakAfter) {
                    items.push({ kind: 'pagebreak' });
                }
            } else if (el.localName === 'tbl') {
                items.push(this.table(el));
            } else if (el.localName === 'sdt') {
                this.body(child(el, 'sdtContent'), items);
            }
        }
    }

    /** Header or footer text: every paragraph, including those in its tables, on its own line. */
    partText(doc, state) {
        if (!doc) {
            return '';
        }
        const lines = [];
        for (const p of doc.getElementsByTagNameNS(W, 'p')) {
            const content = segmentsToContent(this.model, this.paragraphSegments(p, state));
            if (content.text.trim()) {
                lines.push(content.text.trim());
            }
        }
        return lines.join('\n');
    }
}

export async function parseDocx(buffer) {
    const model = newModel('Word document');
    const zip = await readZip(buffer);
    if (!zip.has('word/document.xml')) {
        throw new Error('This file is not a Word document (.docx).');
    }
    const reader = new WordReader(model);
    reader.readStyles(parseXml(await zip.text('word/styles.xml')));
    reader.readNumbering(parseXml(await zip.text('word/numbering.xml')));
    const doc = parseXml(await zip.text('word/document.xml'));
    const body = doc.getElementsByTagNameNS(W, 'body')[0];
    reader.body(body, model.items);

    // Header and footer of the document's last (main) section.
    const rels = {};
    const relDoc = parseXml(await zip.text('word/_rels/document.xml.rels'));
    if (relDoc) {
        for (const rel of relDoc.getElementsByTagName('Relationship')) {
            rels[rel.getAttribute('Id')] = rel.getAttribute('Target');
        }
    }
    const sections = body.getElementsByTagNameNS(W, 'sectPr');
    const section = sections[sections.length - 1];
    const partFor = async (kind) => {
        const refs = section ? Array.from(section.getElementsByTagNameNS(W, kind + 'Reference')) : [];
        const ref = refs.find((r) => attr(r, 'type') === 'default') || refs[0];
        const id = ref ? ref.getAttributeNS(R, 'id') || ref.getAttribute('r:id') : null;
        const target = id && rels[id] ? 'word/' + rels[id].replace(/^\.?\//, '') : null;
        return target ? parseXml(await zip.text(target)) : null;
    };
    const headerState = {};
    model.header = reader.partText(await partFor('header'), headerState);
    const footerState = {};
    model.footer = reader.partText(await partFor('footer'), footerState);
    model.pageNumbers = !!(footerState.pageField || headerState.pageField);
    return model;
}

// ---------- HTML and plain text ----------

function inlineSegments(node, fmt, out) {
    for (const c of node.childNodes) {
        if (c.nodeType === 3) {
            out.push({ text: c.textContent.replace(/\s+/g, ' '), fmt });
        } else if (c.nodeType === 1) {
            const tag = c.tagName.toLowerCase();
            if (tag === 'br') {
                out.push({ text: '\n', fmt });
            } else if (tag === 'img') {
                out.images = (out.images || 0) + 1;
            } else if (tag !== 'script' && tag !== 'style') {
                const style = (c.getAttribute('style') || '').toLowerCase();
                inlineSegments(
                    c,
                    {
                        b: (fmt && fmt.b) || tag === 'b' || tag === 'strong' || /font-weight\s*:\s*(bold|[6-9]00)/.test(style),
                        i: (fmt && fmt.i) || tag === 'i' || tag === 'em' || /font-style\s*:\s*italic/.test(style),
                        u: (fmt && fmt.u) || tag === 'u' || /text-decoration[^;]*underline/.test(style)
                    },
                    out
                );
            }
        }
    }
    return out;
}

function htmlAlign(el) {
    const style = (el.getAttribute('style') || '').toLowerCase();
    const m = /text-align\s*:\s*(left|center|right|justify)/.exec(style);
    const a = m ? m[1] : (el.getAttribute('align') || '').toLowerCase();
    return a === 'center' || a === 'right' || a === 'justify' ? a : '';
}

const BLOCK_TAGS = new Set(['p', 'div', 'section', 'article', 'header', 'footer', 'main', 'center', 'blockquote', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'ul', 'ol', 'li', 'table', 'tbody', 'thead', 'tfoot', 'tr', 'td', 'th', 'hr', 'pre', 'form', 'body']);

function hasBlockChildren(el) {
    return Array.from(el.children).some((c) => BLOCK_TAGS.has(c.tagName.toLowerCase()));
}

function htmlParagraph(model, el, extra) {
    const segments = inlineSegments(el, null, []);
    model.images += segments.images || 0;
    const content = segmentsToContent(model, segments);
    content.text = content.text.replace(/^\s+|\s+$/g, '');
    return { kind: 'para', level: 0, align: htmlAlign(el), list: null, ...content, ...extra };
}

function htmlBody(model, container, items) {
    for (const el of container.childNodes) {
        if (el.nodeType === 3) {
            if (el.textContent.trim()) {
                items.push(htmlParagraph(model, { childNodes: [el], getAttribute: () => null }));
            }
            continue;
        }
        if (el.nodeType !== 1) {
            continue;
        }
        const tag = el.tagName.toLowerCase();
        if (/^h[1-6]$/.test(tag)) {
            items.push({ ...htmlParagraph(model, el), kind: 'heading', level: Math.min(3, Number(tag[1])) });
        } else if (tag === 'ul' || tag === 'ol') {
            for (const li of el.children) {
                if (li.tagName.toLowerCase() === 'li') {
                    items.push(htmlParagraph(model, li, { list: tag }));
                }
            }
        } else if (tag === 'table') {
            const rows = [];
            for (const tr of el.querySelectorAll('tr')) {
                if (tr.closest('table') !== el) {
                    continue;
                }
                const cells = [];
                for (const td of tr.children) {
                    const name = td.tagName.toLowerCase();
                    if (name !== 'td' && name !== 'th') {
                        continue;
                    }
                    const p = htmlParagraph(model, td);
                    cells.push({ html: p.html, text: p.text, formatted: p.formatted, align: p.align });
                }
                rows.push(cells);
            }
            items.push({ kind: 'table', rows });
        } else if (tag === 'img') {
            model.images++;
        } else if (tag === 'hr' || tag === 'script' || tag === 'style') {
            // Nothing to bring over.
        } else if ((el.getAttribute('style') || '').toLowerCase().includes('page-break-before')) {
            items.push({ kind: 'pagebreak' });
            htmlBody(model, el, items);
        } else if (hasBlockChildren(el)) {
            htmlBody(model, el, items);
        } else {
            items.push(htmlParagraph(model, el));
        }
    }
}

export function parseHtml(html) {
    const model = newModel('HTML');
    const doc = new DOMParser().parseFromString(html, 'text/html');
    htmlBody(model, doc.body, model.items);
    return model;
}

export function parseText(text) {
    const model = newModel('Text');
    for (const block of String(text).replace(/\r\n?/g, '\n').split(/\n\s*\n/)) {
        if (block.trim()) {
            model.items.push({ kind: 'para', level: 0, align: '', list: null, ...segmentsToContent(model, [{ text: block.trim(), fmt: null }]) });
        }
    }
    return model;
}

/** A DocBuilder export, or null when the text is not one. */
export function parseExport(text) {
    let data;
    try {
        data = JSON.parse(text);
    } catch (e) {
        return null;
    }
    if (!data || typeof data !== 'object') {
        return null;
    }
    const body = data.format === 'docbuilder-template' ? data.body : data;
    if (!body || !Array.isArray(body.blocks)) {
        return null;
    }
    return { name: data.name || '', baseObject: data.baseObject || '', fileNamePattern: data.fileNamePattern || '', body };
}

/** Pasted content: a DocBuilder export, HTML (for example Salesforce CPQ template content) or plain text. */
export function parsePasted(text) {
    return LOOKS_LIKE_HTML.test(text) ? parseHtml(text) : parseText(text);
}
