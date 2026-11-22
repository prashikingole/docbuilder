/**
 * Turns a loaded context into HTML for the PDF converter.
 * Markup and CSS are kept to what Salesforce's PDF renderer supports (CSS 2.1 plus paged media, no flexbox).
 */
public with sharing class DocBuilderRenderer {
    static final String CSS =
        // Column rows come first so the rules of tables nested inside a column still win.
        'table.cols{width:100%;border-collapse:collapse;table-layout:fixed;margin:0 0 10pt 0}td.col{vertical-align:top;padding:0 10pt 0 0;border:none}' +
        'body{font-family:Helvetica,Arial,sans-serif;font-size:11pt;color:#16202E;line-height:1.45}' +
        'h1{font-size:22pt;margin:0 0 10pt 0}h2{font-size:15pt;margin:14pt 0 6pt 0}h3{font-size:12pt;margin:12pt 0 4pt 0}' +
        'p{margin:0 0 10pt 0}' +
        'table.t{width:100%;border-collapse:collapse;margin:6pt 0 12pt 0}' +
        'table.t th{text-align:left;padding:5pt;border-bottom:1.5pt solid #16202E;font-size:10pt}' +
        'table.t td{padding:5pt;border-bottom:0.5pt solid #C5CBD6;font-size:10pt}' +
        'table.t .r{text-align:right}table.t .c{text-align:center}' +
        'table.t tr.tot td{border-bottom:none;font-weight:bold}table.t tr.tot.sub td{font-weight:normal;color:#3A4658}' +
        'table.t tr.grp td{font-weight:bold;background:#F2F4F7;border-bottom:0.5pt solid #C5CBD6}' +
        'ol{margin:0 0 10pt 0;padding-left:18pt}ul{margin:0 0 10pt 0;padding-left:18pt}li{margin-bottom:4pt}' +
        '.right{text-align:right}.center{text-align:center}' +
        '.rich{margin:0 0 10pt 0}.rich p{margin:0 0 6pt 0}' +
        '.ql-align-center{text-align:center}.ql-align-right{text-align:right}.ql-align-justify{text-align:justify}' +
        '.ql-indent-1{padding-left:3em}.ql-indent-2{padding-left:6em}.ql-indent-3{padding-left:9em}' +
        '.img{margin:0 0 10pt 0}' +
        'table.sig{width:100%;border-collapse:collapse;margin:26pt 0 10pt 0}table.sig td{padding:14pt 16pt 0 0;vertical-align:bottom}' +
        '.sigline{border-bottom:0.75pt solid #16202E;height:30pt}.siglabel{font-size:9pt;color:#3A4658;margin-top:3pt}' +
        '.mk{color:#FFFFFF;font-size:10pt}' +
        'div.dbheader{position:running(dbheader);font-size:9pt;color:#3A4658}' +
        'div.dbfooter{position:running(dbfooter);font-size:9pt;color:#3A4658}' +
        'table.hf{width:100%;border-collapse:collapse}table.hf td{padding:0;vertical-align:middle}' +
        '.pagenumber:before{content:counter(page)}.pagecount:before{content:counter(pages)}';

    static final Integer SIGNERS_PER_ROW = 3;
    public static final String PAGE_BREAK ='<div style="page-break-after:always"></div>';
    static final Map<String, Integer> MARGINS = new Map<String, Integer>{ 'narrow' => 12, 'normal' => 20, 'wide' => 30 };

    public static String render(DocBuilderContext ctx) {
        return document(renderBody(ctx), false, ctx);
    }

    /**
     * Wraps one or more rendered bodies into a complete HTML document for the PDF converter.
     * Page size, margins, header, footer and watermark come from the given (first) template.
     */
    public static String document(String bodyHtml, Boolean draft, DocBuilderContext ctx) {
        String header = headerHtml(ctx);
        String footer = footerHtml(ctx, true);
        String mark = watermarkText(ctx, draft);
        PageBox box = pageBox(ctx, header != null, footer != null);
        String html = '<html><head><style>' + pageCss(box, header != null, footer != null) + CSS + '</style></head><body>';
        // Running elements must come before the content they repeat over.
        if (header != null) {
            html += '<div class="dbheader">' + header + '</div>';
        }
        if (footer != null) {
            html += '<div class="dbfooter">' + footer + '</div>';
        }
        if (mark != null) {
            html += watermarkHtml(mark, box, ctx.section('watermark'), draft == true);
        }
        return html + bodyHtml + '</body></html>';
    }

    /** Page size and margins in millimetres. */
    @TestVisible
    class PageBox {
        String dimensions;
        Decimal width;
        Decimal height;
        Integer side;
        Integer top;
        Integer bottom;
    }

    static PageBox pageBox(DocBuilderContext ctx, Boolean hasHeader, Boolean hasFooter) {
        Map<String, Object> page = ctx.pageSettings();
        String size = page.get('size') == null ? 'A4' : String.valueOf(page.get('size')).toLowerCase();
        Boolean landscape = 'landscape'.equalsIgnoreCase(String.valueOf(page.get('orientation')));
        PageBox box = new PageBox();
        Decimal shortSide;
        Decimal longSide;
        if (size == 'letter') {
            box.dimensions = landscape ? '11in 8.5in' : '8.5in 11in';
            shortSide = 215.9;
            longSide = 279.4;
        } else if (size == 'legal') {
            box.dimensions = landscape ? '14in 8.5in' : '8.5in 14in';
            shortSide = 215.9;
            longSide = 355.6;
        } else {
            box.dimensions = landscape ? 'A4 landscape' : 'A4';
            shortSide = 210;
            longSide = 297;
        }
        box.width = landscape ? longSide : shortSide;
        box.height = landscape ? shortSide : longSide;
        String marginKey = page.get('margin') == null ? 'normal' : String.valueOf(page.get('margin')).toLowerCase();
        box.side = MARGINS.containsKey(marginKey) ? MARGINS.get(marginKey) : 20;
        box.top = box.side + (hasHeader ? 14 : 0);
        box.bottom = box.side + (hasFooter ? 10 : 0);
        return box;
    }

    /**
     * The watermark, centred in the page's content area on every page. The PDF engine places fixed elements from the
     * top-left corner of the content area and ignores percentage heights and vertical centring, so the position is
     * worked out in millimetres from the page size and margins, and the text is sized to fit the page width.
     */
    static final Map<String, String> WATERMARK_SHADES = new Map<String, String>{ 'light' => '#E9EBF0', 'medium' => '#D3D8E1', 'dark' => '#AEB5C2' };
    // Largest text size (pt) across the page, and share of the page a diagonal watermark spans, per size choice.
    static final Map<String, Integer> WATERMARK_MAX_PT = new Map<String, Integer>{ 'fit' => 96, 'large' => 80, 'medium' => 56, 'small' => 36 };
    static final Map<String, Decimal> WATERMARK_SPAN = new Map<String, Decimal>{ 'fit' => 1, 'large' => 0.85, 'medium' => 0.65, 'small' => 0.45 };
    static final Pattern FILE_ID = Pattern.compile('[a-zA-Z0-9]{15,18}');

    static String setting(Map<String, Object> settings, String key, Set<String> allowed, String fallback) {
        String value = settings == null || settings.get(key) == null ? null : String.valueOf(settings.get(key)).toLowerCase();
        return value != null && allowed.contains(value) ? value : fallback;
    }

    /**
     * Diagonal: the PDF engine cannot rotate text, so the designer draws the words at 45 degrees into a transparent
     * image (imageId, and draftImageId for DRAFT), which is placed centred as a square.
     * Across: text centred in the content area, sized to fit the width.
     */
    @TestVisible
    static String watermarkHtml(String mark, PageBox box, Map<String, Object> settings, Boolean draft) {
        Decimal contentWidth = box.width - 2 * box.side;
        Decimal contentHeight = box.height - box.top - box.bottom;
        String size = setting(settings, 'size', WATERMARK_MAX_PT.keySet(), 'fit');
        String shade = setting(settings, 'shade', WATERMARK_SHADES.keySet(), 'light');
        if (setting(settings, 'direction', new Set<String>{ 'across', 'diagonal' }, 'across') == 'diagonal') {
            Object imageId = settings.get(draft ? 'draftImageId' : 'imageId');
            if (imageId != null && FILE_ID.matcher(String.valueOf(imageId)).matches()) {
                Decimal side = (Math.min(contentWidth, contentHeight) * WATERMARK_SPAN.get(size)).setScale(1, RoundingMode.HALF_UP);
                Decimal left = ((contentWidth - side) / 2).setScale(1, RoundingMode.HALF_UP);
                Decimal top = ((contentHeight - side) / 2).setScale(1, RoundingMode.HALF_UP);
                return '<img src="/sfc/servlet.shepherd/version/download/' + imageId + '" style="position:fixed;left:' + left + 'mm;top:' + top +
                    'mm;width:' + side + 'mm;height:' + side + 'mm;z-index:-1"/>';
            }
            // No image (for example the text contains fields): print it across the page instead.
        }
        // Bold capitals in Helvetica average about 0.7 em wide; 1 pt = 0.3528 mm. Leave 10% of the width free.
        Decimal fit = (contentWidth * 0.9) / (Math.max(mark.length(), 1) * 0.7 * 0.3528);
        Integer points = Math.max(Math.min(28, WATERMARK_MAX_PT.get(size)), Math.min(WATERMARK_MAX_PT.get(size), fit.intValue()));
        Decimal lineHeight = points * 0.3528 * 1.2;
        Decimal top = ((contentHeight - lineHeight) / 2).setScale(1, RoundingMode.HALF_UP);
        return '<div style="position:fixed;left:0;top:' + top + 'mm;width:' + contentWidth.setScale(1) + 'mm;text-align:center;' +
            'font-size:' + points + 'pt;line-height:1.2;font-weight:bold;color:' + WATERMARK_SHADES.get(shade) + ';z-index:-1">' + mark + '</div>';
    }

    /** CSS classes for the on-screen watermark, matching the PDF's direction, size and shade. */
    static String watermarkClasses(Map<String, Object> settings) {
        return 'pv-watermark' +
            (setting(settings, 'direction', new Set<String>{ 'across', 'diagonal' }, 'across') == 'diagonal' ? ' diag' : '') +
            ' size-' + setting(settings, 'size', WATERMARK_MAX_PT.keySet(), 'fit') +
            ' shade-' + setting(settings, 'shade', WATERMARK_SHADES.keySet(), 'light');
    }

    /** On-screen approximation of the document for the designer and the generate dialog. */
    public static String preview(DocBuilderContext ctx) {
        String header = headerHtml(ctx);
        String footer = footerHtml(ctx, false);
        String mark = watermarkText(ctx, false);
        return (mark == null ? '' : '<div class="' + watermarkClasses(ctx.section('watermark')) + '">' + mark + '</div>') +
            (header == null ? '' : '<div class="pv-header">' + header + '</div>') +
            '<div class="pv-body">' + renderBody(ctx) + '</div>' +
            (footer == null ? '' : '<div class="pv-footer">' + footer + '</div>');
    }

    static String pageCss(PageBox box, Boolean hasHeader, Boolean hasFooter) {
        return '@page{size:' + box.dimensions + ';margin:' + box.top + 'mm ' + box.side + 'mm ' + box.bottom + 'mm ' + box.side + 'mm;' +
            (hasHeader ? '@top-center{content:element(dbheader)}' : '') +
            (hasFooter ? '@bottom-center{content:element(dbfooter)}' : '') + '}';
    }

    static String headerHtml(DocBuilderContext ctx) {
        Map<String, Object> header = ctx.section('header');
        String logo = imageTag(header.get('logoId'), header.get('logoWidth'), 120);
        String text = ctx.mergeHtml((String) header.get('text'));
        if (logo == null && String.isBlank(text)) {
            return null;
        }
        return '<table class="hf"><tr><td>' + (logo == null ? '' : logo) + '</td><td style="text-align:right">' + text + '</td></tr></table>';
    }

    static String footerHtml(DocBuilderContext ctx, Boolean forPdf) {
        Map<String, Object> footer = ctx.section('footer');
        String text = ctx.mergeHtml((String) footer.get('text'));
        Boolean numbers = footer.get('pageNumbers') == true;
        if (!numbers && String.isBlank(text)) {
            return null;
        }
        String paging = '';
        if (numbers) {
            paging = forPdf ? 'Page <span class="pagenumber"></span> of <span class="pagecount"></span>' : 'Page 1';
        }
        return '<table class="hf"><tr><td>' + text + '</td><td style="text-align:right">' + paging + '</td></tr></table>';
    }

    static String watermarkText(DocBuilderContext ctx, Boolean draft) {
        if (draft == true) {
            return 'DRAFT';
        }
        Map<String, Object> mark = ctx.section('watermark');
        String text = (String) mark.get('text');
        if (String.isBlank(text) || !ctx.passes(mark.get('showIf'), ctx.record, mark.get('showIf') == null ? null : 'watermark')) {
            return null;
        }
        return ctx.mergeText(text, ctx.record, true);
    }

    /** An image stored in Salesforce Files. Returns null when there is no valid file ID. */
    static String imageTag(Object contentVersionId, Object width, Integer defaultWidth) {
        if (contentVersionId == null || !Pattern.matches('[a-zA-Z0-9]{15,18}', String.valueOf(contentVersionId))) {
            return null;
        }
        Integer px = defaultWidth;
        try {
            if (width != null && String.isNotBlank(String.valueOf(width))) {
                px = Decimal.valueOf(String.valueOf(width)).intValue();
            }
        } catch (Exception e) {
            px = defaultWidth;
        }
        px = Math.max(16, Math.min(1000, px));
        return '<img src="/sfc/servlet.shepherd/version/download/' + contentVersionId + '" style="width:' + px + 'px"/>';
    }

    /** Renders the template's blocks only, without the surrounding document. */
    public static String renderBody(DocBuilderContext ctx) {
        String html = '';
        List<String> rowCells = new List<String>();
        List<Integer> rowSpans = new List<Integer>();
        Integer index = 0;
        for (Object b : ctx.blocks()) {
            Map<String, Object> blk = (Map<String, Object>) b;
            index++;
            String id = blk.get('id') == null ? 'block' + index : String.valueOf(blk.get('id'));
            String type = blk.get('type') == null ? 'text' : ((String) blk.get('type')).toLowerCase();

            String piece = renderBlock(ctx, blk, id, type);
            // A block marked "beside" joins the row of the block above it; anything else starts a new row.
            Boolean beside = blk.get('beside') == true && type != 'pagebreak' && !rowCells.isEmpty();
            if (!beside) {
                html += row(rowCells, rowSpans);
                rowCells = new List<String>();
                rowSpans = new List<Integer>();
            }
            rowCells.add(piece);
            rowSpans.add(type == 'pagebreak' ? 100 : spanOf(blk));
        }
        return html + row(rowCells, rowSpans);
    }

    /** The block's share of the page width, in percent: 10 to 100, as set by dragging a column divider. */
    static Integer spanOf(Map<String, Object> blk) {
        try {
            Integer span = blk.get('span') == null ? 100 : Decimal.valueOf(String.valueOf(blk.get('span'))).intValue();
            return span >= 10 && span <= 100 ? span : 100;
        } catch (Exception e) {
            return 100;
        }
    }

    /**
     * One row of blocks. A single full-width block is returned as it is; anything else becomes a fixed-layout
     * table so the PDF engine (CSS 2.1, no flexbox) keeps the columns side by side.
     */
    static String row(List<String> cells, List<Integer> spans) {
        if (cells.isEmpty()) {
            return '';
        }
        if (cells.size() == 1 && spans[0] == 100) {
            return cells[0];
        }
        String out = '<table class="cols"><tr>';
        Integer used = 0;
        for (Integer i = 0; i < cells.size(); i++) {
            used += spans[i];
            out += '<td class="col" style="width:' + spans[i] + '%">' + cells[i] + '</td>';
        }
        if (used < 100) {
            out += '<td class="col" style="width:' + (100 - used) + '%"></td>';
        }
        return out + '</tr></table>';
    }

    /** One block's HTML, or its fallback text when its rule is not met. */
    static String renderBlock(DocBuilderContext ctx, Map<String, Object> blk, String id, String type) {
        if (!ctx.passes(blk.get('showIf'), ctx.record, id)) {
            String fallback = (String) blk.get('elseText');
            return String.isNotBlank(fallback) ? '<p>' + ctx.mergeHtml(fallback) + '</p>' : '';
        }
        if (type == 'heading') {
            Integer level = blk.get('level') == null ? 1 : Integer.valueOf(blk.get('level'));
            level = Math.max(1, Math.min(3, level));
            return '<h' + level + alignClass(blk, '') + '>' + ctx.mergeHtml((String) blk.get('text')) + '</h' + level + '>';
        }
        if (type == 'table') {
            return table(ctx, blk);
        }
        if (type == 'terms') {
            return terms(ctx, blk, id);
        }
        if (type == 'pagebreak') {
            return PAGE_BREAK;
        }
        if (type == 'signature') {
            return signature(ctx, blk);
        }
        if (type == 'custom') {
            return customContent(ctx, blk);
        }
        if (type == 'image') {
            String image = imageTag(blk.get('contentVersionId'), blk.get('width'), 200);
            return image == null ? '' : '<div' + alignClass(blk, 'img') + '>' + image + '</div>';
        }
        if (blk.get('rich') == true) {
            return '<div' + alignClass(blk, 'rich') + '>' + ctx.mergeRich((String) blk.get('text')) + '</div>';
        }
        return '<p' + alignClass(blk, '') + '>' + ctx.mergeHtml((String) blk.get('text')) + '</p>';
    }

    // ---------- Custom content: an Apex class or a Visualforce page ----------

    static final Pattern CLASS_NAME = Pattern.compile('^[A-Za-z][A-Za-z0-9_]*(\\.[A-Za-z][A-Za-z0-9_]*)?$');
    static final Pattern PAGE_NAME = Pattern.compile('^[A-Za-z][A-Za-z0-9_]*$');
    static final Pattern CODE_DROP_WITH_CONTENT = Pattern.compile('(?is)<(script|iframe|object|embed|noscript|template|svg|math|form|head|title)\\b.*?</\\1\\s*>');
    static final Pattern CODE_DROP_TAG = Pattern.compile('(?is)</?(script|iframe|object|embed|link|meta|base|form|input|button|select|textarea|html|body|head|frame|frameset|applet)\\b[^>]*>');
    static final Pattern CODE_EVENT_ATTR = Pattern.compile('(?is)\\s(on[a-z]+|formaction|srcdoc)\\s*=\\s*("[^"]*"|\'[^\']*\'|[^\\s>]+)');
    static final Pattern CODE_SCRIPT_URL = Pattern.compile('(?is)\\s(href|src|action|background)\\s*=\\s*("\\s*(javascript|vbscript|data):[^"]*"|\'\\s*(javascript|vbscript|data):[^\']*\')');

    /**
     * Content written by a developer (Apex) or an admin (Visualforce). It is trusted to lay itself out, so tables
     * and styles are kept, but anything that could run code or send data anywhere is removed: scripts, frames,
     * forms, event attributes and script URLs. Previews are cleaned again in the browser with a strict allowlist.
     */
    public static String cleanCode(String html) {
        if (String.isBlank(html)) {
            return '';
        }
        String out = CODE_DROP_WITH_CONTENT.matcher(html).replaceAll('');
        out = CODE_DROP_TAG.matcher(out).replaceAll('');
        out = CODE_EVENT_ATTR.matcher(out).replaceAll('');
        return CODE_SCRIPT_URL.matcher(out).replaceAll('');
    }

    /** The provider an Apex class name refers to, after checking it implements DocBuilderContentProvider. */
    public static DocBuilderContentProvider contentProvider(String className) {
        if (String.isBlank(className) || !CLASS_NAME.matcher(className.trim()).matches()) {
            throw new DocBuilder.DocBuilderException('"' + className + '" is not a valid Apex class name.');
        }
        Type t = Type.forName(className.trim());
        if (t == null) {
            throw new DocBuilder.DocBuilderException('There is no Apex class called "' + className + '" that DocBuilder can use. It must be global or public in this org.');
        }
        Object instance;
        try {
            instance = t.newInstance();
        } catch (Exception e) {
            throw new DocBuilder.DocBuilderException('Apex class "' + className + '" could not be created: ' + e.getMessage());
        }
        if (!(instance instanceof DocBuilderContentProvider)) {
            throw new DocBuilder.DocBuilderException('Apex class "' + className + '" does not implement DocBuilderContentProvider.');
        }
        return (DocBuilderContentProvider) instance;
    }

    static String customContent(DocBuilderContext ctx, Map<String, Object> blk) {
        String kind = blk.get('source') == null ? 'apex' : String.valueOf(blk.get('source'));
        String html;
        if (kind == 'visualforce') {
            html = visualforceContent(ctx, (String) blk.get('page'));
        } else {
            String className = (String) blk.get('className');
            if (String.isBlank(className)) {
                return '';
            }
            DocBuilderContentRequest request = new DocBuilderContentRequest();
            request.recordId = ctx.recordId;
            request.objectName = ctx.baseObject;
            request.settings = (String) blk.get('settings');
            request.language = ctx.language;
            try {
                html = contentProvider(className).render(request);
            } catch (DocBuilder.DocBuilderException e) {
                throw e;
            } catch (Exception e) {
                throw new DocBuilder.DocBuilderException('The Apex class "' + className + '" in a Custom content block failed: ' + e.getMessage());
            }
        }
        return '<div' + alignClass(blk, 'custom') + '>' + cleanCode(html) + '</div>';
    }

    /**
     * The body of a Visualforce page rendered for this record (?id=recordId). Salesforce treats this like a
     * callout, so it must happen before anything is saved in the same transaction; DocBuilder renders before it saves.
     */
    static String visualforceContent(DocBuilderContext ctx, String pageName) {
        if (String.isBlank(pageName)) {
            return '';
        }
        String name = pageName.trim();
        if (!PAGE_NAME.matcher(name).matches()) {
            throw new DocBuilder.DocBuilderException('"' + pageName + '" is not a valid Visualforce page name.');
        }
        // Page content cannot be fetched while Apex tests run.
        if (Test.isRunningTest()) {
            return '<p>[Visualforce page ' + name.escapeHtml4() + ']</p>';
        }
        PageReference page = new PageReference('/apex/' + name);
        if (ctx.recordId != null) {
            page.getParameters().put('id', ctx.recordId);
        }
        String html;
        try {
            html = page.getContent().toString();
        } catch (Exception e) {
            throw new DocBuilder.DocBuilderException(
                'The Visualforce page "' + name + '" could not be included: ' + e.getMessage() +
                (e.getMessage().containsIgnoreCase('uncommitted') ? ' Generate the document before saving other changes in the same step (for example, in a separate Flow transaction).' : '')
            );
        }
        // Only the page's body is kept; its <head> (scripts, Salesforce styles) is left out.
        Integer open = html.toLowerCase().indexOf('<body');
        if (open >= 0) {
            Integer start = html.indexOf('>', open);
            Integer close = html.toLowerCase().lastIndexOf('</body>');
            html = start < 0 ? '' : html.substring(start + 1, close > start ? close : html.length());
        }
        return html;
    }

    /** Checks a Custom content block's Apex class for the designer: null when it can be used, otherwise why not. */
    public static String checkContentProvider(String className) {
        try {
            contentProvider(className);
            return null;
        } catch (Exception e) {
            return e.getMessage();
        }
    }

    /**
     * One signing area per signer. For e-signature the provider's hidden marker is printed in white where
     * each field belongs; otherwise it is a plain line to sign by hand.
     */
    static String signature(DocBuilderContext ctx, Map<String, Object> blk) {
        List<DocBuilderSign.Signer> signers = ctx.resolveSigners();
        if (signers.isEmpty()) {
            DocBuilderSign.Signer generic = new DocBuilderSign.Signer();
            generic.role = 'Signature';
            signers.add(generic);
        }
        Boolean showDate = blk.get('showDate') != false;
        Boolean showName = blk.get('showName') == true;
        // Up to three signing areas side by side; more signers continue on further rows.
        Integer perRow = Math.min(SIGNERS_PER_ROW, signers.size());
        String width = ' style="width:' + (100 / perRow) + '%"';
        String html = '<table class="sig"><tr>';
        Integer n = 0;
        for (DocBuilderSign.Signer signer : signers) {
            if (n > 0 && Math.mod(n, perRow) == 0) {
                html += '</tr><tr>';
            }
            n++;
            String caption = signer.role == null ? '' : signer.role.escapeHtml4();
            if (String.isNotBlank(signer.name)) {
                caption += (String.isBlank(caption) ? '' : ', ') + signer.name.escapeHtml4();
            }
            // The s1..s6 class lets on-screen previews colour each signer's area; the PDF ignores it.
            html += '<td class="s' + (Math.mod(n - 1, 6) + 1) + '"' + width + '><div class="sigline">' + mark(ctx, n, 'signature') + '</div><div class="siglabel">' + caption + '</div>';
            if (showName) {
                html += '<div class="siglabel">Name ' + mark(ctx, n, 'name') + '</div>';
            }
            if (showDate) {
                html += '<div class="siglabel">Date ' + mark(ctx, n, 'date') + '</div>';
            }
            html += '</td>';
        }
        // Fill the last row so the areas keep the same width.
        while (Math.mod(n, perRow) != 0) {
            html += '<td' + width + '></td>';
            n++;
        }
        return html + '</tr></table>';
    }

    static String mark(DocBuilderContext ctx, Integer signerNumber, String fieldType) {
        if (ctx.signProvider == null) {
            return '';
        }
        String marker = ctx.signProvider.marker(signerNumber, fieldType);
        return String.isBlank(marker) ? '' : '<span class="mk">' + marker.escapeHtml4() + '</span>';
    }

    static String alignClass(Map<String, Object> source, String baseClass) {
        String align = (String) source.get('align');
        String classes = baseClass;
        if (align == 'right' || align == 'center') {
            classes = (classes + ' ' + align).trim();
        }
        return String.isBlank(classes) ? '' : ' class="' + classes + '"';
    }

    static String cellClass(Map<String, Object> column) {
        String align = (String) column.get('align');
        if (align == 'right') {
            return ' class="r"';
        }
        if (align == 'center') {
            return ' class="c"';
        }
        return '';
    }

    /**
     * The columns that print. Each column's "show" setting decides:
     *   always (default) | filled: only when at least one shown row has a value (blank and zero count as empty)
     *   | rule: only when its showIf rule on the record is met.
     */
    @TestVisible
    static List<Object> shownColumns(DocBuilderContext ctx, List<Object> columns, List<SObject> rows, String blockId) {
        List<Object> shown = new List<Object>();
        Integer index = 0;
        for (Object c : columns) {
            Map<String, Object> column = (Map<String, Object>) c;
            String show = column.get('show') == null ? 'always' : String.valueOf(column.get('show'));
            Boolean keep = true;
            if (show == 'rule') {
                keep = ctx.passes(column.get('showIf'), ctx.record, column.get('showIf') == null ? null : blockId + '|col' + index);
            } else if (show == 'filled') {
                keep = anyValue(ctx, rows, (String) column.get('field'));
            }
            if (keep) {
                shown.add(column);
            }
            index++;
        }
        return shown;
    }

    static Boolean anyValue(DocBuilderContext ctx, List<SObject> rows, String field) {
        for (SObject row : rows) {
            Object value = ctx.resolve(row, field);
            if (value == null || String.isBlank(String.valueOf(value))) {
                continue;
            }
            if ((value instanceof Decimal || value instanceof Double || value instanceof Integer || value instanceof Long) && Decimal.valueOf(String.valueOf(value)) == 0) {
                continue;
            }
            return true;
        }
        return false;
    }

    static String table(DocBuilderContext ctx, Map<String, Object> blk) {
        List<SObject> rows = ctx.rowsFor((String) blk.get('source'), blk.get('rowFilter'));
        rows = ctx.sorted(rows, (String) blk.get('orderBy'), 'DESC'.equalsIgnoreCase((String) blk.get('orderDirection')));
        if (rows.isEmpty() && blk.get('hideWhenEmpty') == true) {
            return '';
        }
        List<Object> allColumns = DocBuilderContext.asList(blk.get('columns'));
        List<Object> columns = shownColumns(ctx, allColumns, rows, (String) blk.get('id'));
        if (columns.isEmpty() && !allColumns.isEmpty()) {
            // Every column is hidden for this record, so there is nothing to print.
            return '';
        }

        String html = '<table class="t"><thead><tr>';
        for (Object c : columns) {
            Map<String, Object> column = (Map<String, Object>) c;
            String header = column.get('header') == null ? (String) column.get('field') : (String) column.get('header');
            html += '<th' + cellClass(column) + '>' + header.escapeHtml4() + '</th>';
        }
        html += '</tr></thead><tbody>';
        String groupBy = (String) blk.get('groupBy');
        if (String.isBlank(groupBy)) {
            html += tableRows(ctx, columns, rows);
        } else {
            // Rows are grouped by one field, groups in the order their first row appears (so sort the table to order them).
            Map<String, List<SObject>> groups = new Map<String, List<SObject>>();
            for (SObject row : rows) {
                String label = ctx.formatValue(row, groupBy, null);
                label = String.isBlank(label) ? '(none)' : label;
                if (!groups.containsKey(label)) {
                    groups.put(label, new List<SObject>());
                }
                groups.get(label).add(row);
            }
            for (String label : groups.keySet()) {
                html += '<tr class="grp"><td colspan="' + Math.max(1, columns.size()) + '">' + label.escapeHtml4() + '</td></tr>';
                html += tableRows(ctx, columns, groups.get(label));
                if (blk.get('groupTotals') == true) {
                    html += totalRows(ctx, blk, columns, groups.get(label), label + ': ');
                }
            }
        }
        html += totalRows(ctx, blk, columns, rows, '');
        return html + '</tbody></table>';
    }

    static String tableRows(DocBuilderContext ctx, List<Object> columns, List<SObject> rows) {
        String html = '';
        for (SObject row : rows) {
            html += '<tr>';
            for (Object c : columns) {
                Map<String, Object> column = (Map<String, Object>) c;
                String value = ctx.formatValue(row, (String) column.get('field'), (String) column.get('format'));
                html += '<td' + cellClass(column) + '>' + value.escapeHtml4() + '</td>';
            }
            html += '</tr>';
        }
        return html;
    }

    /** The table's summary rows over the given rows; prefix names the group for subtotals. */
    static String totalRows(DocBuilderContext ctx, Map<String, Object> blk, List<Object> columns, List<SObject> rows, String prefix) {
        String html = '';
        for (Object t : DocBuilderContext.asList(blk.get('totals'))) {
            Map<String, Object> total = (Map<String, Object>) t;
            String label = prefix + (total.get('label') == null ? '' : (String) total.get('label'));
            String value = ctx.formatTableTotal((String) total.get('calc'), (String) total.get('format'), (String) blk.get('source'), rows);
            html += '<tr class="tot' + (String.isBlank(prefix) ? '' : ' sub') + '">';
            if (columns.size() > 1) {
                html += '<td class="r" colspan="' + (columns.size() - 1) + '">' + label.escapeHtml4() + '</td>';
                html += '<td class="r">' + value.escapeHtml4() + '</td></tr>';
            } else {
                // A one-column table has no spare cell for the label, so label and value share the cell.
                html += '<td class="r">' + (String.isBlank(label) ? '' : label.escapeHtml4() + ' ') + value.escapeHtml4() + '</td></tr>';
            }
        }
        return html;
    }

    static String terms(DocBuilderContext ctx, Map<String, Object> blk, String blockId) {
        String items = '';
        Integer index = 0;
        for (Object i : DocBuilderContext.asList(blk.get('items'))) {
            Map<String, Object> item = (Map<String, Object>) i;
            index++;
            String itemId = item.get('id') == null ? blockId + '.item' + index : String.valueOf(item.get('id'));
            // An ordered list renumbers itself, so numbering closes up when a clause is left out.
            if (ctx.passes(item.get('showIf'), ctx.record, item.get('showIf') == null ? null : itemId)) {
                items += '<li>' + ctx.mergeHtml((String) item.get('text')) + '</li>';
            }
        }
        if (String.isBlank(items)) {
            return '';
        }
        String title = (String) blk.get('title');
        return (String.isBlank(title) ? '' : '<h3>' + ctx.mergeHtml(title) + '</h3>') + '<ol>' + items + '</ol>';
    }
}
