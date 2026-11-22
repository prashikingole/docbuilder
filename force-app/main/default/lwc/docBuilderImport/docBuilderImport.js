import { LightningElement } from 'lwc';
import describeObject from '@salesforce/apex/DocBuilderDesignerController.describeObject';
import suggestFields from '@salesforce/apex/DocBuilderDesignerController.suggestFields';
import importTemplate from '@salesforce/apex/DocBuilderDesignerController.importTemplate';
import listImportSources from '@salesforce/apex/DocBuilderDesignerController.listImportSources';
import loadImportSource from '@salesforce/apex/DocBuilderDesignerController.loadImportSource';
import createStandardQuoteTemplate from '@salesforce/apex/DocBuilderDesignerController.createStandardQuoteTemplate';
import { parseDocx, parseHtml, parseText, parsePasted, parseExport, escapeHtml, simplify, PLACEHOLDER } from 'c/docBuilderImportParse';

const AS_TEXT = '__text';
const LEAVE_OUT = '__drop';
const MAX_FILE_BYTES = 15 * 1024 * 1024;

function tokenIds(text) {
    const ids = [];
    const re = new RegExp(PLACEHOLDER.source, 'g');
    let m;
    while ((m = re.exec(text || '')) !== null) {
        ids.push(Number(m[1]));
    }
    return ids;
}

function uid() {
    return 'b' + Math.random().toString(36).slice(2, 10);
}

/**
 * Import wizard: reads a Word file, HTML, text or a DocBuilder export, lets the admin match each merge field
 * and repeating table to Salesforce, then creates the template as a draft. Fires "imported" with
 * detail.state (the new template), or "close".
 */
export default class DocBuilderImport extends LightningElement {
    step = 'source';
    busy = false;
    error;

    name = '';
    baseObject = '';
    pasted = '';
    file;

    model;
    children = [];
    tables = [];
    parentMap = {};

    // ---------- Step 1: source ----------

    // Where the template comes from: a file or pasted content, a template in this org, or the standard quote layout.
    mode = 'file';
    orgTemplates;
    orgPick = '';

    get modeButtons() {
        return [
            { value: 'file', label: 'A file or pasted text' },
            { value: 'org', label: 'From this org' },
            { value: 'standard', label: 'Standard Salesforce quote' }
        ].map((m) => ({ ...m, cls: m.value === this.mode ? 'seg-btn on' : 'seg-btn', pressed: m.value === this.mode ? 'true' : 'false' }));
    }

    get isFileMode() {
        return this.mode === 'file';
    }

    get isOrgMode() {
        return this.mode === 'org';
    }

    get isStandardMode() {
        return this.mode === 'standard';
    }

    get needsObject() {
        return this.mode !== 'standard';
    }

    get orgOptions() {
        return (this.orgTemplates || []).map((c) => ({ label: `${c.sourceLabel}: ${c.name}`, value: c.source + ':' + c.id }));
    }

    get noOrgTemplates() {
        return Array.isArray(this.orgTemplates) && this.orgTemplates.length === 0;
    }

    get nextLabel() {
        return this.mode === 'standard' ? 'Create draft template' : 'Next';
    }

    handleMode(event) {
        this.mode = event.currentTarget.dataset.mode;
        this.error = undefined;
        if (this.mode === 'org' && !this.orgTemplates) {
            this.work(async () => {
                this.orgTemplates = await listImportSources();
            });
        }
        if (this.mode === 'standard' && !this.name) {
            this.name = 'Standard Quote';
        }
    }

    handleOrgPick(event) {
        this.orgPick = event.detail.value;
        const [source, id] = this.orgPick.split(':');
        const found = (this.orgTemplates || []).find((c) => c.source === source && c.id === id);
        if (found) {
            this.name = found.name ? found.name.slice(0, 80) : this.name;
            if (found.baseObject) {
                this.baseObject = found.baseObject;
            }
        }
    }

    /** Reads the chosen org template: CPQ arrives as HTML built from its sections, the others as their file. */
    async readOrgTemplate() {
        if (!this.orgPick) {
            throw new Error('Choose a template first.');
        }
        const [source, recordId] = this.orgPick.split(':');
        const loaded = await loadImportSource({ source, recordId });
        let model;
        if (loaded.kind === 'docx') {
            const bytes = Uint8Array.from(atob(loaded.content), (c) => c.charCodeAt(0));
            model = await parseDocx(bytes.buffer);
        } else if (loaded.kind === 'html') {
            model = parseHtml(loaded.content);
        } else {
            model = parseText(loaded.content);
        }
        if (loaded.header && !model.header) {
            model.header = loaded.header;
        }
        if (loaded.footer && !model.footer) {
            model.footer = loaded.footer;
        }
        model.notes = [...(model.notes || []), ...(loaded.notes || [])];
        if (loaded.baseObject && !this.baseObject.trim()) {
            this.baseObject = loaded.baseObject;
        }
        return { model };
    }

    get isSource() {
        return this.step === 'source';
    }

    get isMap() {
        return this.step === 'map';
    }

    get fieldExamples() {
        return '{{Name}}, {!Name}, «Name», <<Name>>';
    }

    get fileLabel() {
        return this.file ? this.file.name : '';
    }

    handleFile(event) {
        const files = event.target.files;
        this.file = files && files.length ? files[0] : undefined;
        this.error = undefined;
        if (this.file && !this.name) {
            this.name = this.file.name.replace(/\.[^.]+$/, '').slice(0, 80);
        }
    }

    handleInput(event) {
        this[event.target.dataset.field] = event.detail.value;
        this.error = undefined;
    }

    handleClose() {
        this.dispatchEvent(new CustomEvent('close'));
    }

    async work(task) {
        this.busy = true;
        this.error = undefined;
        try {
            await task();
        } catch (e) {
            this.error = (e && e.body && e.body.message) || (e && e.message) || 'Something went wrong.';
        } finally {
            this.busy = false;
        }
    }

    async readSource() {
        if (this.file) {
            if (this.file.size > MAX_FILE_BYTES) {
                throw new Error('The file is larger than 15 MB. Remove large pictures from it and try again.');
            }
            const lower = this.file.name.toLowerCase();
            if (lower.endsWith('.docx') || lower.endsWith('.dotx')) {
                return { model: await parseDocx(await this.file.arrayBuffer()) };
            }
            if (lower.endsWith('.doc')) {
                throw new Error('Older .doc files cannot be read. Open the file in Word and save it as .docx, then import that.');
            }
            const text = await this.file.text();
            if (lower.endsWith('.json')) {
                const exported = parseExport(text);
                if (!exported) {
                    throw new Error('This JSON file is not a DocBuilder template export.');
                }
                return { exported };
            }
            if (lower.endsWith('.htm') || lower.endsWith('.html')) {
                return { model: parseHtml(text) };
            }
            return { model: parseText(text) };
        }
        if (this.pasted && this.pasted.trim()) {
            const exported = parseExport(this.pasted.trim());
            return exported ? { exported } : { model: parsePasted(this.pasted) };
        }
        throw new Error('Choose a file or paste the template first.');
    }

    handleRead() {
        this.work(async () => {
            if (this.mode === 'standard') {
                const state = await createStandardQuoteTemplate({ name: this.name.trim() });
                this.dispatchEvent(new CustomEvent('imported', { detail: { state } }));
                return;
            }
            const source = this.mode === 'org' ? await this.readOrgTemplate() : await this.readSource();
            if (source.exported) {
                await this.createFromExport(source.exported);
                return;
            }
            if (!this.name.trim() || !this.baseObject.trim()) {
                throw new Error('Enter a template name and the object it is built on.');
            }
            const info = await describeObject({ objectName: this.baseObject.trim() });
            this.baseObject = info.name;
            this.children = info.children || [];
            this.model = source.model;
            if (!this.model.items.length && !this.model.header && !this.model.footer) {
                throw new Error('Nothing to import was found in it.');
            }
            this.setUpTables();
            this.parentMap = {};
            await this.refreshSuggestions();
            this.step = 'map';
        });
    }

    async createFromExport(exported) {
        const name = this.name.trim() || exported.name;
        const baseObject = this.baseObject.trim() || exported.baseObject;
        if (!name || !baseObject) {
            throw new Error('Enter a template name and the object it is built on.');
        }
        const state = await importTemplate({ name, baseObject, fileNamePattern: exported.fileNamePattern, bodyJson: JSON.stringify(exported.body) });
        this.dispatchEvent(new CustomEvent('imported', { detail: { state } }));
    }

    // ---------- Tables ----------

    findList(hint) {
        // A dotted or slashed name (Opportunity.OpportunityLineItems, ./QuoteLineItems/QuoteLineItem) is tried part by part.
        const parts = String(hint || '')
            .split(/[./]/)
            .filter((p) => p);
        for (const part of parts.length > 1 ? [hint, ...parts] : [hint]) {
            const found = this.findListPart(part);
            if (found) {
                return found;
            }
        }
        return null;
    }

    findListPart(hint) {
        const want = simplify(hint);
        if (!want) {
            return null;
        }
        const exact = this.children.find((c) => simplify(c.name) === want || simplify(c.label) === want || simplify(c.childObject) === want);
        if (exact) {
            return exact;
        }
        // Shortened names, e.g. LineItems for QuoteLineItems.
        return this.children.find((c) => simplify(c.name).endsWith(want) || want.endsWith(simplify(c.name))) || null;
    }

    setUpTables() {
        const tokens = this.model.tokens;
        this.tables = [];
        this.model.items.forEach((item, itemIndex) => {
            if (item.kind !== 'table') {
                return;
            }
            const fieldIds = (cell) => tokenIds(cell.text).filter((id) => tokens[id].kind === 'field');
            const templateRow = item.rows.findIndex((row) => row.some((cell) => fieldIds(cell).length));
            let hint = null;
            const markerIds = [];
            for (const row of item.rows) {
                for (const cell of row) {
                    for (const id of tokenIds(cell.text)) {
                        if (tokens[id].kind === 'listStart') {
                            hint = hint || tokens[id].listName;
                            markerIds.push(id);
                        }
                    }
                }
            }
            if (!hint && templateRow >= 0) {
                // Fields written as List.Field, e.g. OpportunityLineItems.Quantity.
                const prefixes = item.rows[templateRow].flatMap((cell) => fieldIds(cell)).map((id) => tokens[id].name.split('.')[0]);
                hint = prefixes.find((p) => this.findList(p)) || null;
            }
            const list = hint ? this.findList(hint) : null;
            const headerRow = templateRow > 0 && !item.rows[templateRow - 1].some((cell) => fieldIds(cell).length) ? templateRow - 1 : -1;
            this.tables.push({
                key: 't' + itemIndex,
                itemIndex,
                number: this.tables.length + 1,
                templateRow,
                headerRow,
                list: list && templateRow >= 0 ? list.name : '',
                childObject: list && templateRow >= 0 ? list.childObject : '',
                rowTokenIds: templateRow >= 0 ? item.rows[templateRow].flatMap((cell) => fieldIds(cell)) : [],
                markerIds,
                mapping: {},
                preview: item.rows
                    .slice(0, 2)
                    .map((row) => row.map((cell) => this.plainPreview(cell.text)).join(' | '))
                    .join(' / ')
                    .slice(0, 140)
            });
        });
    }

    plainPreview(text) {
        return (text || '').replace(new RegExp(PLACEHOLDER.source, 'g'), (m, id) => '«' + this.model.tokens[Number(id)].name + '»').replace(/\s+/g, ' ').trim();
    }

    repeatTokenIds() {
        const ids = new Set();
        this.tables.filter((t) => t.list).forEach((t) => t.rowTokenIds.forEach((id) => ids.add(id)));
        return ids;
    }

    get parentNames() {
        const inTables = this.repeatTokenIds();
        const names = [];
        this.model.tokens.forEach((t, id) => {
            // Conditions ({{#if Field}}) name a field too, so it is mapped like any other.
            if ((t.kind === 'field' || (t.kind === 'ifStart' && !t.complex)) && !inTables.has(id) && !names.includes(t.name)) {
                names.push(t.name);
            }
        });
        return names;
    }

    tableNames(table) {
        const names = [];
        table.rowTokenIds.forEach((id) => {
            const name = this.model.tokens[id].name;
            if (!names.includes(name)) {
                names.push(name);
            }
        });
        return names;
    }

    /** Fills in suggestions for fields not matched yet; choices already made are kept. */
    async refreshSuggestions() {
        const parentNames = this.parentNames.filter((n) => !(n in this.parentMap));
        if (parentNames.length) {
            const found = await suggestFields({ objectName: this.baseObject, tokens: parentNames, listName: null });
            const map = { ...this.parentMap };
            parentNames.forEach((n) => {
                map[n] = found[n] || '';
            });
            this.parentMap = map;
        }
        const tables = [];
        for (const table of this.tables) {
            if (table.list) {
                const names = this.tableNames(table).filter((n) => !(n in table.mapping));
                if (names.length) {
                    // eslint-disable-next-line no-await-in-loop
                    const found = await suggestFields({ objectName: table.childObject, tokens: names, listName: table.list });
                    const mapping = { ...table.mapping };
                    names.forEach((n) => {
                        mapping[n] = found[n] || '';
                    });
                    tables.push({ ...table, mapping });
                    continue;
                }
            }
            tables.push(table);
        }
        this.tables = tables;
    }

    get listOptions() {
        return [{ label: 'Print it as a fixed table', value: '' }, ...this.children.map((c) => ({ label: `${c.label} (${c.name})`, value: c.name })).sort((a, b) => a.label.localeCompare(b.label))];
    }

    handleTableList(event) {
        const key = event.target.dataset.key;
        const value = event.detail.value;
        const child = this.children.find((c) => c.name === value);
        this.tables = this.tables.map((t) => (t.key === key ? { ...t, list: value, childObject: child ? child.childObject : '', mapping: {} } : t));
        this.work(() => this.refreshSuggestions());
    }

    handleParentField(event) {
        this.parentMap = { ...this.parentMap, [event.target.dataset.name]: event.detail.value };
    }

    handleTableField(event) {
        const { key, name } = event.target.dataset;
        const value = event.detail.value;
        this.tables = this.tables.map((t) => (t.key === key ? { ...t, mapping: { ...t.mapping, [name]: value } } : t));
    }

    // ---------- Step 2: review ----------

    fieldRow(name, value) {
        const matched = !!value && !value.startsWith('__');
        return {
            name,
            value,
            matched,
            status: matched ? 'Matched' : value === LEAVE_OUT ? 'Left out' : value === AS_TEXT ? 'Printed as text' : 'Choose a field',
            statusCls: matched ? 'status ok' : value ? 'status' : 'status warn'
        };
    }

    get parentRows() {
        return this.parentNames.map((n) => this.fieldRow(n, this.parentMap[n] || ''));
    }

    get hasParentRows() {
        return this.parentRows.length > 0;
    }

    get tableRows() {
        const hasTemplateRow = (t) => t.templateRow >= 0;
        return this.tables.map((t) => ({
            ...t,
            canRepeat: hasTemplateRow(t),
            repeats: !!t.list,
            listLabel: 'Table ' + t.number,
            fields: t.list ? this.tableNames(t).map((n) => this.fieldRow(n, t.mapping[n] || '')) : []
        }));
    }

    get hasTables() {
        return this.tables.length > 0;
    }

    get summary() {
        const m = this.model;
        if (!m) {
            return '';
        }
        const count = (kind) => m.items.filter((i) => i.kind === kind).length;
        const fieldNames = new Set(m.tokens.filter((t) => t.kind === 'field').map((t) => t.name));
        const parts = [`${count('heading')} headings`, `${count('para')} paragraphs`, `${count('table')} tables`, `${fieldNames.size} different merge fields`];
        return `Read from the ${m.source.toLowerCase()}: ` + parts.join(', ') + '.';
    }

    get warnings() {
        const m = this.model;
        const out = [];
        if (!m) {
            return out;
        }
        if (m.images) {
            out.push(`${m.images} picture${m.images === 1 ? ' was' : 's were'} not brought over. Add logos and images with an Image block afterwards.`);
        }
        const tableMarkers = new Set(this.tables.flatMap((t) => t.markerIds));
        if (m.tokens.some((t, id) => t.kind === 'listStart' && !tableMarkers.has(id))) {
            out.push('Repeating sections outside tables are not converted. Use a table for repeating rows.');
        }
        const unmatched = this.parentRows.filter((r) => !r.value).length + this.tableRows.reduce((n, t) => n + t.fields.filter((f) => !f.value).length, 0);
        if (unmatched) {
            out.push(`${unmatched} merge field${unmatched === 1 ? ' is' : 's are'} not matched yet. Unless you choose a field, they print as [Name] so they are easy to find.`);
        }
        const conditions = m.tokens.filter((t) => t.kind === 'ifStart' && !t.complex).length;
        if (conditions) {
            out.push(`${conditions} condition${conditions === 1 ? '' : 's'} ({{#if Field}}) will become DocBuilder conditions once the field is matched. Unmatched ones are left out and their text always prints.`);
        }
        const controls = m.tokens.filter((t) => t.kind === 'control' || t.complex).length;
        if (controls) {
            out.push(`${controls} tag${controls === 1 ? '' : 's'} with logic DocBuilder can't read directly (for example DocuSign Gen Conditional tags or comparisons) ${controls === 1 ? 'was' : 'were'} left out. Add those conditions in the designer.`);
        }
        if (m.wordIfs) {
            out.push(`${m.wordIfs} Word IF field${m.wordIfs === 1 ? '' : 's'} (conditional text, common in Conga templates) came over as the text Word last showed. Add the condition in the designer.`);
        }
        (m.notes || []).forEach((note) => out.push(note));
        return out;
    }

    get hasWarnings() {
        return this.warnings.length > 0;
    }

    handleBack() {
        this.step = 'source';
        this.error = undefined;
    }

    // ---------- Building the template ----------

    /**
     * Makes the condition tags in one piece of text safe to save. A condition whose field wasn't matched
     * ({{#if __drop}}) keeps its own text and loses its {{else}} part. If the tags don't pair up within the text
     * (a condition opened in one paragraph group and closed in another), every condition tag is removed and
     * all the text is kept, so the template never fails to generate.
     */
    balanceSections(text) {
        if (!text || text.indexOf('{{') < 0) {
            return text;
        }
        const tag = new RegExp('\\{\\{\\s*(#if\\s+[^}]+?|else|/if)\\s*\\}\\}', 'g');
        const stack = [];
        let out = '';
        let last = 0;
        let valid = true;
        const hidden = () => stack.some((frame) => frame.drop && frame.inElse);
        let m;
        while ((m = tag.exec(text)) !== null) {
            if (!hidden()) {
                out += text.slice(last, m.index);
            }
            last = m.index + m[0].length;
            const name = m[1].trim();
            if (name.startsWith('#if')) {
                const drop = name.includes('__drop');
                stack.push({ drop, inElse: false });
                if (!drop && !hidden()) {
                    out += m[0];
                }
            } else if (name === 'else') {
                const top = stack[stack.length - 1];
                if (!top) {
                    valid = false;
                    break;
                }
                if (!top.drop && !hidden()) {
                    out += m[0];
                }
                top.inElse = true;
            } else {
                const top = stack.pop();
                if (!top) {
                    valid = false;
                    break;
                }
                if (!top.drop && !hidden()) {
                    out += m[0];
                }
            }
        }
        if (valid && stack.length === 0) {
            return out + text.slice(last);
        }
        return text.replace(tag, '');
    }

    /** Replaces placeholders with {{field}} tokens, [Name] text or nothing. (Not called render: that name is reserved by LWC.) */
    fillTokens(text, map, html) {
        return (text || '').replace(new RegExp(PLACEHOLDER.source, 'g'), (m, id) => {
            const token = this.model.tokens[Number(id)];
            if (token.kind === 'ifStart') {
                // Becomes a DocBuilder condition when its field is matched; otherwise it is dropped
                // (balanceSections then removes its else and end too).
                const target = token.complex ? null : map[token.name];
                return target && !target.startsWith('__') ? '{{#if ' + (token.negate ? 'not ' : '') + target + '}}' : '{{#if __drop}}';
            }
            if (token.kind === 'else') {
                return '{{else}}';
            }
            if (token.kind === 'ifEnd') {
                return '{{/if}}';
            }
            if (token.kind !== 'field') {
                return '';
            }
            const value = map[token.name];
            if (value && !value.startsWith('__')) {
                return '{{' + value + '}}';
            }
            if (value === LEAVE_OUT) {
                return '';
            }
            const shown = '[' + token.name + ']';
            return html ? escapeHtml(shown) : shown;
        });
    }

    textBlock(paras) {
        // Leading, trailing and repeated empty paragraphs are dropped.
        const kept = [];
        paras.forEach((p) => {
            const empty = !p.text.trim();
            if (empty && (!kept.length || !kept[kept.length - 1].text.trim())) {
                return;
            }
            kept.push(p);
        });
        while (kept.length && !kept[kept.length - 1].text.trim()) {
            kept.pop();
        }
        if (!kept.length) {
            return null;
        }
        const aligns = new Set(kept.map((p) => p.align || ''));
        const rich = kept.some((p) => p.formatted || p.list) || aligns.size > 1;
        if (!rich) {
            const block = { id: uid(), type: 'text', text: kept.map((p) => this.fillTokens(p.text, this.parentMap, false)).join('\n') };
            const align = kept[0].align;
            if (align) {
                block.align = align;
            }
            return block;
        }
        let html = '';
        let openList = null;
        kept.forEach((p) => {
            const inner = this.fillTokens(p.html, this.parentMap, true) || '<br/>';
            if (p.list !== openList) {
                if (openList) {
                    html += '</' + openList + '>';
                }
                if (p.list) {
                    html += '<' + p.list + '>';
                }
                openList = p.list;
            }
            if (p.list) {
                html += '<li>' + inner + '</li>';
            } else {
                html += '<p' + (p.align ? ' class="ql-align-' + p.align + '"' : '') + '>' + inner + '</p>';
            }
        });
        if (openList) {
            html += '</' + openList + '>';
        }
        return { id: uid(), type: 'text', rich: true, text: html };
    }

    cellBlock(cell) {
        const block = cell.formatted
            ? { id: uid(), type: 'text', rich: true, text: '<p>' + this.fillTokens(cell.html, this.parentMap, true) + '</p>' }
            : { id: uid(), type: 'text', text: this.fillTokens(cell.text, this.parentMap, false) };
        if (cell.align) {
            block.align = cell.align;
        }
        return block;
    }

    /** A table without repeating rows: each row becomes up to four blocks side by side. */
    fixedRows(rows, blocks) {
        rows.forEach((row) => {
            if (!row.some((cell) => cell.text.trim())) {
                return;
            }
            if (row.length === 1) {
                blocks.push(this.cellBlock(row[0]));
                return;
            }
            if (row.length > 4) {
                blocks.push({ id: uid(), type: 'text', text: row.map((cell) => this.fillTokens(cell.text, this.parentMap, false).replace(/\n/g, ' ')).join('   ') });
                return;
            }
            const base = Math.floor(100 / row.length);
            row.forEach((cell, i) => {
                const block = this.cellBlock(cell);
                block.span = i === row.length - 1 ? 100 - base * (row.length - 1) : base;
                if (i > 0) {
                    block.beside = true;
                }
                blocks.push(block);
            });
        });
    }

    tableBlocks(item, table, blocks) {
        if (!table || !table.list) {
            this.fixedRows(item.rows, blocks);
            return;
        }
        const tokens = this.model.tokens;
        const firstRow = table.headerRow >= 0 ? table.headerRow : table.templateRow;
        this.fixedRows(item.rows.slice(0, firstRow), blocks);
        const header = table.headerRow >= 0 ? item.rows[table.headerRow] : null;
        const columns = [];
        item.rows[table.templateRow].forEach((cell, ci) => {
            const id = tokenIds(cell.text).find((n) => tokens[n].kind === 'field');
            if (id === undefined) {
                return;
            }
            const name = tokens[id].name;
            const value = table.mapping[name];
            if (!value || value.startsWith('__')) {
                return;
            }
            const column = { header: header && header[ci] ? this.fillTokens(header[ci].text, this.parentMap, false).replace(/\n/g, ' ').trim() : name, field: value };
            if (cell.align === 'right' || cell.align === 'center') {
                column.align = cell.align;
            }
            columns.push(column);
        });
        if (!columns.length) {
            this.fixedRows(item.rows, blocks);
            return;
        }
        blocks.push({ id: uid(), type: 'table', source: table.list, columns });
        // Rows under the repeating row, such as totals, print under the table.
        item.rows.slice(table.templateRow + 1).forEach((row) => {
            const text = row
                .map((cell) => this.fillTokens(cell.text, this.parentMap, false).replace(/\n/g, ' ').trim())
                .filter((t) => t)
                .join('   ');
            if (text) {
                blocks.push({ id: uid(), type: 'text', text, align: 'right' });
            }
        });
    }

    buildBody() {
        const blocks = [];
        let paras = [];
        const flush = () => {
            const block = this.textBlock(paras);
            if (block) {
                blocks.push(block);
            }
            paras = [];
        };
        this.model.items.forEach((item, index) => {
            if (item.kind === 'para') {
                paras.push(item);
                return;
            }
            flush();
            if (item.kind === 'heading') {
                const text = this.fillTokens(item.text, this.parentMap, false).replace(/\n/g, ' ').trim();
                if (text) {
                    const block = { id: uid(), type: 'heading', level: item.level || 1, text };
                    if (item.align) {
                        block.align = item.align;
                    }
                    blocks.push(block);
                }
            } else if (item.kind === 'pagebreak') {
                if (blocks.length && blocks[blocks.length - 1].type !== 'pagebreak') {
                    blocks.push({ id: uid(), type: 'pagebreak' });
                }
            } else if (item.kind === 'table') {
                this.tableBlocks(item, this.tables.find((t) => t.itemIndex === index), blocks);
            }
        });
        flush();
        while (blocks.length && blocks[blocks.length - 1].type === 'pagebreak') {
            blocks.pop();
        }
        // Conditions must open and close within one block of text.
        blocks.forEach((block) => {
            if (typeof block.text === 'string') {
                block.text = this.balanceSections(block.text);
            }
        });
        const page = {};
        const header = this.balanceSections(this.fillTokens(this.model.header, this.parentMap, false)).trim();
        const footer = this.balanceSections(this.fillTokens(this.model.footer, this.parentMap, false)).trim();
        if (header) {
            page.header = { text: header };
        }
        if (footer || this.model.pageNumbers) {
            page.footer = { text: footer, pageNumbers: this.model.pageNumbers };
        }
        return { blocks, calculations: [], page, signers: [], conditions: [] };
    }

    handleCreate() {
        this.work(async () => {
            const body = this.buildBody();
            if (!body.blocks.length) {
                throw new Error('Nothing would be left in the template. Check the field choices.');
            }
            const state = await importTemplate({ name: this.name.trim(), baseObject: this.baseObject, fileNamePattern: '', bodyJson: JSON.stringify(body) });
            this.dispatchEvent(new CustomEvent('imported', { detail: { state } }));
        });
    }
}
