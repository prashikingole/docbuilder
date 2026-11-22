/**
 * Templates already in this org that the Import wizard can read directly, from the tools people move from:
 *   Salesforce CPQ quote templates (rebuilt from their sections, line columns and quote terms),
 *   Conga Composer, DocuSign Gen and OmniStudio document templates (their attached Word or HTML file).
 * A tool that is not installed is simply not offered. Every query runs with the user's access; object and
 * field names come from describe, never from user input.
 *
 * Also builds a ready-made template laid out like Salesforce's standard quote template, whose definition
 * Salesforce does not expose through any API.
 */
public with sharing class DocBuilderImportSources {
    static final Integer MAX_FILE_BYTES = 3 * 1024 * 1024;
    static final Integer MAX_TEMPLATES = 200;

    public class Candidate {
        @AuraEnabled
        public String source;
        @AuraEnabled
        public String sourceLabel;
        @AuraEnabled
        public Id id;
        @AuraEnabled
        public String name;
        @AuraEnabled
        public String baseObject;
    }

    public class Loaded {
        /** docx (content is base64), html or text. */
        @AuraEnabled
        public String kind;
        @AuraEnabled
        public String content;
        @AuraEnabled
        public String fileName;
        @AuraEnabled
        public String baseObject;
        @AuraEnabled
        public String header;
        @AuraEnabled
        public String footer;
        @AuraEnabled
        public List<String> notes = new List<String>();
    }

    class Source {
        String key;
        String label;
        String objectName;
        String baseObject;
        Source(String key, String label, String objectName, String baseObject) {
            this.key = key;
            this.label = label;
            this.objectName = objectName;
            this.baseObject = baseObject;
        }
    }

    /** Tests can point a tool at a standard object, since the tools' packages are not installed where tests run. */
    @TestVisible
    static Map<String, String> testObjects = new Map<String, String>();

    static List<Source> sources() {
        List<Source> all = new List<Source>{
            new Source('cpq', 'Salesforce CPQ', 'SBQQ__QuoteTemplate__c', 'SBQQ__Quote__c'),
            new Source('conga', 'Conga Composer', 'APXTConga4__Conga_Template__c', null),
            new Source('docusign', 'DocuSign Gen', 'dfsle__GenTemplate__c', null),
            new Source('omnistudio', 'OmniStudio', 'DocumentTemplate', null),
            new Source('vlocity', 'OmniStudio (Vlocity)', 'vlocity_cmt__DocumentTemplate__c', null)
        };
        for (Source s : all) {
            if (testObjects.containsKey(s.key)) {
                s.objectName = testObjects.get(s.key);
            }
        }
        return all;
    }

    static Map<String, Schema.SObjectType> globalTypes;

    static Schema.DescribeSObjectResult describeIfPresent(String objectName) {
        if (globalTypes == null) {
            globalTypes = Schema.getGlobalDescribe();
        }
        Schema.SObjectType t = globalTypes.get(objectName.toLowerCase());
        if (t == null) {
            return null;
        }
        Schema.DescribeSObjectResult d = t.getDescribe();
        return d.isAccessible() && d.isQueryable() ? d : null;
    }

    /** The first of these fields that exists and is readable on the object, or null. */
    static String firstField(Schema.DescribeSObjectResult d, List<String> names) {
        Map<String, Schema.SObjectField> fields = d.fields.getMap();
        for (String name : names) {
            Schema.SObjectField f = fields.get(name.toLowerCase());
            if (f != null && f.getDescribe().isAccessible()) {
                return f.getDescribe().getName();
            }
        }
        return null;
    }

    /** Every readable field of an object, for reading one template record in full. */
    static List<String> readableFields(Schema.DescribeSObjectResult d) {
        List<String> names = new List<String>();
        for (Schema.SObjectField f : d.fields.getMap().values()) {
            Schema.DescribeFieldResult fd = f.getDescribe();
            if (fd.isAccessible() && fd.getType() != Schema.DisplayType.BASE64 && fd.getType() != Schema.DisplayType.ADDRESS && fd.getType() != Schema.DisplayType.LOCATION) {
                names.add(fd.getName());
            }
        }
        return names;
    }

    /** Templates found in the installed tools, by tool. Tools that are not installed are left out. */
    public static List<Candidate> candidates() {
        List<Candidate> found = new List<Candidate>();
        for (Source source : sources()) {
            Schema.DescribeSObjectResult d = describeIfPresent(source.objectName);
            if (d == null) {
                continue;
            }
            String nameField = firstField(d, new List<String>{ 'APXTConga4__Name__c', 'Name' });
            String baseField = firstField(d, new List<String>{ 'dfsle__SourceObject__c', 'dfsle__SourceObjectName__c', 'TargetObjectName', 'vlocity_cmt__ApplicableTypes__c' });
            List<String> fields = new List<String>{ 'Id', nameField };
            if (baseField != null) {
                fields.add(baseField);
            }
            String soql = 'SELECT ' + String.join(fields, ', ') + ' FROM ' + d.getName() + ' ORDER BY ' + nameField + ' LIMIT ' + MAX_TEMPLATES;
            for (SObject row : Database.query(soql, AccessLevel.USER_MODE)) {
                Candidate c = new Candidate();
                c.source = source.key;
                c.sourceLabel = source.label;
                c.id = row.Id;
                c.name = String.valueOf(row.get(nameField));
                c.baseObject = baseField != null && row.get(baseField) != null ? String.valueOf(row.get(baseField)) : source.baseObject;
                found.add(c);
            }
        }
        return found;
    }

    /** The content of one template found by candidates(). */
    public static Loaded load(String sourceKey, Id recordId) {
        Source source;
        for (Source s : sources()) {
            if (s.key == sourceKey) {
                source = s;
            }
        }
        if (source == null || recordId == null || String.valueOf(recordId.getSObjectType()).toLowerCase() != source.objectName.toLowerCase()) {
            throw new DocBuilder.DocBuilderException('That template could not be found.');
        }
        if (source.key == 'cpq') {
            return loadCpq(recordId);
        }
        Loaded loaded = attachedFile(recordId, source.key == 'omnistudio');
        loaded.baseObject = source.baseObject;
        return loaded;
    }

    // ---------- Files attached to a template record (Conga, DocuSign Gen, OmniStudio) ----------

    static final Set<String> READABLE = new Set<String>{ 'docx', 'dotx', 'htm', 'html', 'txt' };

    static Loaded attachedFile(Id recordId, Boolean omniStudio) {
        Set<Id> documentIds = new Set<Id>();
        // OmniStudio keeps its template file in DocumentTemplateContentDoc rather than a plain file link.
        if (omniStudio && describeIfPresent('DocumentTemplateContentDoc') != null) {
            for (SObject link : Database.queryWithBinds(
                'SELECT ContentDocumentId FROM DocumentTemplateContentDoc WHERE DocumentTemplateId = :recordId',
                new Map<String, Object>{ 'recordId' => recordId },
                AccessLevel.USER_MODE
            )) {
                documentIds.add((Id) link.get('ContentDocumentId'));
            }
        }
        for (ContentDocumentLink link : [SELECT ContentDocumentId FROM ContentDocumentLink WHERE LinkedEntityId = :recordId WITH USER_MODE]) {
            documentIds.add(link.ContentDocumentId);
        }
        if (!documentIds.isEmpty()) {
            for (ContentVersion v : [
                SELECT Title, FileExtension, ContentSize, VersionData
                FROM ContentVersion
                WHERE ContentDocumentId IN :documentIds AND IsLatest = TRUE
                WITH USER_MODE
                ORDER BY LastModifiedDate DESC
            ]) {
                String ext = v.FileExtension == null ? '' : v.FileExtension.toLowerCase();
                if (READABLE.contains(ext)) {
                    return fileContent(v.Title + '.' + ext, ext, v.ContentSize, v.VersionData);
                }
            }
        }
        // Older Conga and Vlocity templates keep the file as an attachment.
        for (Attachment a : [SELECT Name, BodyLength, Body FROM Attachment WHERE ParentId = :recordId WITH USER_MODE ORDER BY LastModifiedDate DESC LIMIT 10]) {
            String ext = a.Name.contains('.') ? a.Name.substringAfterLast('.').toLowerCase() : '';
            if (READABLE.contains(ext)) {
                return fileContent(a.Name, ext, a.BodyLength, a.Body);
            }
        }
        throw new DocBuilder.DocBuilderException('No Word (.docx) or HTML file is attached to this template. Download it from the other tool and upload it with "A file" instead.');
    }

    static Loaded fileContent(String fileName, String ext, Integer size, Blob data) {
        if (size != null && size > MAX_FILE_BYTES) {
            throw new DocBuilder.DocBuilderException('The template file is larger than 3 MB. Download it and upload it with "A file" instead.');
        }
        Loaded loaded = new Loaded();
        loaded.fileName = fileName;
        if (ext == 'docx' || ext == 'dotx') {
            loaded.kind = 'docx';
            loaded.content = EncodingUtil.base64Encode(data);
        } else {
            loaded.kind = ext == 'txt' ? 'text' : 'html';
            loaded.content = data.toString();
        }
        return loaded;
    }

    // ---------- Salesforce CPQ ----------

    static Loaded loadCpq(Id templateId) {
        Schema.DescribeSObjectResult templateType = describeIfPresent('SBQQ__QuoteTemplate__c');
        Map<String, Object> template = Database.queryWithBinds(
                'SELECT ' + String.join(readableFields(templateType), ', ') + ' FROM SBQQ__QuoteTemplate__c WHERE Id = :templateId',
                new Map<String, Object>{ 'templateId' => templateId },
                AccessLevel.USER_MODE
            )[0]
            .getPopulatedFieldsAsMap();

        List<Map<String, Object>> sections = new List<Map<String, Object>>();
        Schema.DescribeSObjectResult sectionType = describeIfPresent('SBQQ__TemplateSection__c');
        if (sectionType != null) {
            String pageBreak = firstField(sectionType, new List<String>{ 'SBQQ__PageBreakBefore__c' });
            String soql =
                'SELECT Name, SBQQ__Content__r.Name, SBQQ__Content__r.SBQQ__Type__c, SBQQ__Content__r.SBQQ__Markup__c, SBQQ__Content__r.SBQQ__RawMarkup__c' +
                (pageBreak == null ? '' : ', ' + pageBreak) +
                ' FROM SBQQ__TemplateSection__c WHERE SBQQ__Template__c = :templateId ORDER BY SBQQ__DisplayOrder__c';
            for (SObject s : Database.queryWithBinds(soql, new Map<String, Object>{ 'templateId' => templateId }, AccessLevel.USER_MODE)) {
                SObject content = s.getSObject('SBQQ__Content__r');
                sections.add(new Map<String, Object>{
                    'name' => s.get('Name'),
                    'type' => content == null ? null : content.get('SBQQ__Type__c'),
                    'markup' => content == null ? null : (content.get('SBQQ__Markup__c') != null ? content.get('SBQQ__Markup__c') : content.get('SBQQ__RawMarkup__c')),
                    'pageBreak' => pageBreak == null ? false : s.get(pageBreak) == true
                });
            }
        }

        List<Map<String, Object>> columns = new List<Map<String, Object>>();
        if (describeIfPresent('SBQQ__LineColumn__c') != null) {
            for (SObject c : Database.queryWithBinds(
                'SELECT Name, SBQQ__FieldName__c FROM SBQQ__LineColumn__c WHERE SBQQ__Template__c = :templateId ORDER BY SBQQ__DisplayOrder__c',
                new Map<String, Object>{ 'templateId' => templateId },
                AccessLevel.USER_MODE
            )) {
                columns.add(new Map<String, Object>{ 'heading' => c.get('Name'), 'field' => c.get('SBQQ__FieldName__c') });
            }
        }

        List<Map<String, Object>> terms = new List<Map<String, Object>>();
        Schema.DescribeSObjectResult termType = describeIfPresent('SBQQ__QuoteTerm__c');
        if (termType != null) {
            String active = firstField(termType, new List<String>{ 'SBQQ__Active__c' });
            for (SObject t : Database.query(
                'SELECT SBQQ__Body__c FROM SBQQ__QuoteTerm__c' + (active == null ? '' : ' WHERE ' + active + ' = TRUE') + ' ORDER BY SBQQ__PrintOrder__c LIMIT 200',
                AccessLevel.USER_MODE
            )) {
                terms.add(new Map<String, Object>{ 'body' => t.get('SBQQ__Body__c') });
            }
        }

        Loaded loaded = cpqTemplate(template, sections, columns, terms);
        loaded.fileName = String.valueOf(template.get('Name'));
        return loaded;
    }

    static final Pattern TEMPLATE_FIELD = Pattern.compile('\\{!\\s*template\\.([A-Za-z0-9_]+)\\s*\\}');

    /** {!template.Field} is the same for every quote, so its value is filled in now instead of being mapped. */
    static String fillTemplateFields(String markup, Map<String, Object> template) {
        if (String.isBlank(markup)) {
            return '';
        }
        Map<String, Object> byLowerName = new Map<String, Object>();
        for (String key : template.keySet()) {
            byLowerName.put(key.toLowerCase(), template.get(key));
        }
        Matcher m = TEMPLATE_FIELD.matcher(markup);
        String out = '';
        Integer last = 0;
        while (m.find()) {
            Object value = byLowerName.get(m.group(1).toLowerCase());
            out += markup.substring(last, m.start()) + (value == null ? '' : String.valueOf(value).escapeHtml4());
            last = m.end();
        }
        return out + markup.substring(last);
    }

    /**
     * Turns a CPQ quote template into HTML the wizard reads like any imported page: HTML sections as they are,
     * the Line Items section as a table repeating over the quote lines (columns from Line Column records),
     * Quote Terms as a numbered list, and page breaks where a section asks for one. Template values are filled in.
     */
    public static Loaded cpqTemplate(Map<String, Object> template, List<Map<String, Object>> sections, List<Map<String, Object>> columns, List<Map<String, Object>> terms) {
        Loaded loaded = new Loaded();
        loaded.kind = 'html';
        loaded.baseObject = 'SBQQ__Quote__c';
        String html = '';
        for (Map<String, Object> section : sections) {
            String type = section.get('type') == null ? 'HTML' : String.valueOf(section.get('type'));
            String name = section.get('name') == null ? type : String.valueOf(section.get('name'));
            String part;
            if (type == 'Line Items') {
                part = lineItemsTable(columns);
                if (columns.isEmpty()) {
                    loaded.notes.add('The Line Items section "' + name + '" has no line columns, so its table has none. Add columns in the designer.');
                }
            } else if (type == 'Quote Terms') {
                part = '<h3>' + name.escapeHtml4() + '</h3><ol>';
                for (Map<String, Object> term : terms) {
                    part += '<li>' + fillTemplateFields(String.valueOf(term.get('body')), template) + '</li>';
                }
                part += '</ol>';
            } else if (type == 'Custom') {
                part = '';
                loaded.notes.add('The section "' + name + '" is a Visualforce page in CPQ. Add a Custom block for it in the designer.');
            } else {
                part = fillTemplateFields(section.get('markup') == null ? '' : String.valueOf(section.get('markup')), template);
            }
            html += (section.get('pageBreak') == true ? '<div style="page-break-before:always">' : '<div>') + part + '</div>';
        }
        if (sections.isEmpty()) {
            loaded.notes.add('This CPQ template has no sections, so it uses CPQ\'s standard layout. Only its line columns were brought over.');
            html = lineItemsTable(columns);
        }
        loaded.content = html;
        // Company details from the template, as CPQ prints them at the top.
        List<String> company = new List<String>();
        for (String key : new List<String>{ 'SBQQ__CompanyName__c', 'SBQQ__CompanyStreet__c', 'SBQQ__CompanyCity__c', 'SBQQ__CompanyPhone__c' }) {
            Object value = valueIgnoringCase(template, key);
            if (value != null && String.isNotBlank(String.valueOf(value))) {
                company.add(String.valueOf(value));
            }
        }
        loaded.header = company.isEmpty() ? null : String.join(company, ' · ');
        return loaded;
    }

    static Object valueIgnoringCase(Map<String, Object> values, String key) {
        for (String k : values.keySet()) {
            if (k.equalsIgnoreCase(key)) {
                return values.get(k);
            }
        }
        return null;
    }

    static String lineItemsTable(List<Map<String, Object>> columns) {
        String head = '';
        String row = '';
        for (Integer i = 0; i < columns.size(); i++) {
            Map<String, Object> c = columns[i];
            String field = c.get('field') == null ? '' : String.valueOf(c.get('field'));
            head += '<th>' + (c.get('heading') == null ? field : String.valueOf(c.get('heading'))).escapeHtml4() + '</th>';
            row += '<td>' + (i == 0 ? '{{#each SBQQ__LineItems__r}}' : '') + '{!line.' + field.escapeHtml4() + '}' + (i == columns.size() - 1 ? '{{/each}}' : '') + '</td>';
        }
        return '<table><tr>' + head + '</tr><tr>' + row + '</tr></table>';
    }

    // ---------- Salesforce standard quote layout ----------

    static Map<String, Object> block(String type, Map<String, Object> props) {
        Map<String, Object> b = new Map<String, Object>{ 'id' => 'q' + Math.abs(Crypto.getRandomInteger()), 'type' => type };
        b.putAll(props);
        return b;
    }

    /**
     * A template laid out like Salesforce's standard quote template: company details, quote details, prepared
     * by and for, bill-to and ship-to, the line items, totals (each shown only when it has a value), the
     * description as terms, and signing lines. Company details come from this org's company information.
     */
    public static String standardQuoteBody() {
        List<Organization> orgs = [SELECT Name, Street, City, State, PostalCode, Country, Phone FROM Organization WITH USER_MODE LIMIT 1];
        List<String> company = new List<String>();
        if (!orgs.isEmpty()) {
            Organization o = orgs[0];
            for (String part : new List<String>{ o.Street, String.join(new List<String>{ o.City == null ? '' : o.City, o.State == null ? '' : o.State, o.PostalCode == null ? '' : o.PostalCode }, ' ').trim(), o.Country, o.Phone }) {
                if (String.isNotBlank(part)) {
                    company.add(part);
                }
            }
        }
        String companyName = orgs.isEmpty() ? 'Your company' : orgs[0].Name;
        List<Object> blocks = new List<Object>{
            block('heading', new Map<String, Object>{ 'level' => 1, 'text' => companyName }),
            block('text', new Map<String, Object>{ 'text' => String.join(company, '\n'), 'span' => 60 }),
            block('text', new Map<String, Object>{ 'text' => 'Quote Number: {{QuoteNumber}}\nCreated: {{CreatedDate|date}}\n{{#if ExpirationDate}}Expires: {{ExpirationDate}}{{/if}}', 'span' => 40, 'beside' => true, 'align' => 'right' }),
            block('text', new Map<String, Object>{ 'text' => 'Prepared By\n{{Owner.Name}}\n{{#if Owner.Email}}{{Owner.Email}}{{/if}}\n{{#if Owner.Phone}}{{Owner.Phone}}{{/if}}', 'span' => 50 }),
            block('text', new Map<String, Object>{ 'text' => 'Contact\n{{Contact.Name}}\n{{#if Email}}{{Email}}{{/if}}\n{{#if Phone}}{{Phone}}{{/if}}', 'span' => 50, 'beside' => true }),
            block('text', new Map<String, Object>{ 'text' => 'Bill To\n{{BillingName}}\n{{#if BillingStreet}}{{BillingStreet}}\n{{/if}}{{BillingCity}} {{BillingState}} {{BillingPostalCode}}\n{{BillingCountry}}', 'span' => 50 }),
            block('text', new Map<String, Object>{ 'text' => 'Ship To\n{{ShippingName}}\n{{#if ShippingStreet}}{{ShippingStreet}}\n{{/if}}{{ShippingCity}} {{ShippingState}} {{ShippingPostalCode}}\n{{ShippingCountry}}', 'span' => 50, 'beside' => true }),
            block('table', new Map<String, Object>{
                'source' => 'QuoteLineItems',
                'orderBy' => 'SortOrder',
                'columns' => new List<Object>{
                    new Map<String, Object>{ 'header' => 'Product', 'field' => 'Product2.Name' },
                    new Map<String, Object>{ 'header' => 'Line Item Description', 'field' => 'Description', 'show' => 'filled' },
                    new Map<String, Object>{ 'header' => 'Quantity', 'field' => 'Quantity', 'align' => 'right' },
                    new Map<String, Object>{ 'header' => 'Sales Price', 'field' => 'UnitPrice', 'align' => 'right' },
                    new Map<String, Object>{ 'header' => 'Discount', 'field' => 'Discount', 'align' => 'right', 'show' => 'filled' },
                    new Map<String, Object>{ 'header' => 'Total Price', 'field' => 'TotalPrice', 'align' => 'right' }
                }
            }),
            block('text', new Map<String, Object>{
                'align' => 'right',
                'text' => 'Subtotal: {{Subtotal}}\n{{#if Discount}}Discount: {{Discount|percent}}\n{{/if}}Total Price: {{TotalPrice}}\n{{#if Tax}}Tax: {{Tax}}\n{{/if}}{{#if ShippingHandling}}Shipping and Handling: {{ShippingHandling}}\n{{/if}}Grand Total: {{GrandTotal}}'
            }),
            block('heading', new Map<String, Object>{ 'level' => 3, 'text' => 'Terms and Conditions' }),
            block('text', new Map<String, Object>{ 'text' => '{{Description}}' }),
            block('signature', new Map<String, Object>{ 'showDate' => true, 'showName' => true })
        };
        Map<String, Object> body = new Map<String, Object>{
            'blocks' => blocks,
            'calculations' => new List<Object>(),
            'page' => new Map<String, Object>{ 'footer' => new Map<String, Object>{ 'text' => companyName + ' · Quote {{QuoteNumber}}', 'pageNumbers' => true } },
            'signers' => new List<Object>{
                new Map<String, Object>{ 'role' => 'Customer', 'name' => '{{Contact.Name}}', 'email' => '{{Contact.Email}}' },
                new Map<String, Object>{ 'role' => 'Company', 'name' => '{{Owner.Name}}', 'email' => '{{Owner.Email}}' }
            },
            'conditions' => new List<Object>()
        };
        return JSON.serialize(body);
    }
}
