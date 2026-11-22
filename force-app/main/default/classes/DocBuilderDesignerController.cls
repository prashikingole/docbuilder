/**
 * Server side of the Template Designer: template and version lifecycle, schema lookups for the
 * field picker, live preview, health check and translations.
 */
public with sharing class DocBuilderDesignerController {
    public class TemplateState {
        @AuraEnabled
        public Id templateId;
        @AuraEnabled
        public String name;
        @AuraEnabled
        public String baseObject;
        @AuraEnabled
        public String status;
        @AuraEnabled
        public String fileNamePattern;
        @AuraEnabled
        public String languages;
        @AuraEnabled
        public String defaultLanguage;
        @AuraEnabled
        public Id versionId;
        @AuraEnabled
        public Decimal versionNumber;
        @AuraEnabled
        public String versionStatus;
        @AuraEnabled
        public Decimal activeVersionNumber;
        @AuraEnabled
        public String bodyJson;
    }

    public class FieldInfo {
        @AuraEnabled
        public String name;
        @AuraEnabled
        public String label;
        @AuraEnabled
        public String type;
        @AuraEnabled
        public String relationshipName;
        @AuraEnabled
        public String referenceTo;
        /** Active picklist values, so rules offer a list to choose from instead of free typing. */
        @AuraEnabled
        public List<String> values;
    }

    public class ChildInfo {
        @AuraEnabled
        public String name;
        @AuraEnabled
        public String childObject;
        /** Plural label of the child object, e.g. Opportunity Products. */
        @AuraEnabled
        public String label;
        /** The lookup field on the child that points back to the parent. */
        @AuraEnabled
        public String field;
    }

    public class ObjectInfo {
        @AuraEnabled
        public String name;
        @AuraEnabled
        public String label;
        @AuraEnabled
        public List<FieldInfo> fields = new List<FieldInfo>();
        @AuraEnabled
        public List<ChildInfo> children = new List<ChildInfo>();
    }

    @AuraEnabled
    public static List<DocTemplate__c> listTemplates() {
        return [SELECT Id, Name, Base_Object__c, Status__c FROM DocTemplate__c WITH USER_MODE ORDER BY Name LIMIT 500];
    }

    @AuraEnabled
    public static TemplateState createTemplate(String name, String baseObject) {
        try {
            if (String.isBlank(name) || String.isBlank(baseObject)) {
                throw new DocBuilder.DocBuilderException('A name and an object are required.');
            }
            Schema.DescribeSObjectResult described = describe(baseObject);
            DocTemplate__c template = new DocTemplate__c(Name = name.trim().left(80), Base_Object__c = described.getName(), Status__c = 'Draft', Default_Language__c = 'en');
            insert as user template;
            insert as user new DocTemplateVersion__c(Template__c = template.Id, Version_Number__c = 1, Status__c = 'Draft', Body_JSON__c = '{"blocks":[],"calculations":[]}');
            return loadTemplate(template.Id);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * Creates a template from an imported design (Word, HTML, text or a DocBuilder export). It starts as a draft,
     * so nobody can generate from it until it has been checked and activated in the designer.
     */
    @AuraEnabled
    public static TemplateState importTemplate(String name, String baseObject, String fileNamePattern, String bodyJson) {
        try {
            if (String.isBlank(name) || String.isBlank(baseObject)) {
                throw new DocBuilder.DocBuilderException('A name and an object are required.');
            }
            if (String.isBlank(bodyJson) || bodyJson.length() > 131072) {
                throw new DocBuilder.DocBuilderException('The imported template is empty or too large. Split it into smaller templates.');
            }
            Object parsed = JSON.deserializeUntyped(bodyJson);
            if (!(parsed instanceof Map<String, Object>) || !(((Map<String, Object>) parsed).get('blocks') instanceof List<Object>)) {
                throw new DocBuilder.DocBuilderException('The imported content is not a DocBuilder template.');
            }
            Schema.DescribeSObjectResult described = describe(baseObject);
            DocTemplate__c template = new DocTemplate__c(
                Name = name.trim().left(80),
                Base_Object__c = described.getName(),
                File_Name_Pattern__c = String.isBlank(fileNamePattern) ? null : fileNamePattern.left(255),
                Status__c = 'Draft',
                Default_Language__c = 'en'
            );
            insert as user template;
            insert as user new DocTemplateVersion__c(Template__c = template.Id, Version_Number__c = 1, Status__c = 'Draft', Body_JSON__c = bodyJson);
            return loadTemplate(template.Id);
        } catch (Exception e) {
            throw userError(e);
        }
    }

    /** Templates in installed tools (CPQ, Conga, DocuSign Gen, OmniStudio) that can be imported directly. */
    @AuraEnabled
    public static List<DocBuilderImportSources.Candidate> listImportSources() {
        try {
            return DocBuilderImportSources.candidates();
        } catch (Exception e) {
            throw userError(e);
        }
    }

    /** The content of one of those templates, for the Import wizard to read. */
    @AuraEnabled
    public static DocBuilderImportSources.Loaded loadImportSource(String source, Id recordId) {
        try {
            return DocBuilderImportSources.load(source, recordId);
        } catch (Exception e) {
            throw userError(e);
        }
    }

    /** Creates a draft Quote template laid out like Salesforce's standard quote template. */
    @AuraEnabled
    public static TemplateState createStandardQuoteTemplate(String name) {
        return importTemplate(String.isBlank(name) ? 'Standard Quote' : name, 'Quote', 'Quote {{QuoteNumber}}', DocBuilderImportSources.standardQuoteBody());
    }

    /** Suggested Salesforce field for each merge field found in an imported template (see DocBuilderImport). */
    @AuraEnabled
    public static Map<String, String> suggestFields(String objectName, List<String> tokens, String listName) {
        try {
            return new DocBuilderImport().suggest(objectName, tokens, listName);
        } catch (Exception e) {
            throw userError(e);
        }
    }

    /** Loads the draft version if there is one, otherwise the active version. */
    @AuraEnabled
    public static TemplateState loadTemplate(Id templateId) {
        DocTemplate__c template = [
            SELECT Id, Name, Base_Object__c, Status__c, File_Name_Pattern__c, Languages__c, Default_Language__c, Active_Version__c, Active_Version__r.Version_Number__c
            FROM DocTemplate__c
            WHERE Id = :templateId
            WITH USER_MODE
        ];
        TemplateState state = new TemplateState();
        state.templateId = template.Id;
        state.name = template.Name;
        state.baseObject = template.Base_Object__c;
        state.status = template.Status__c;
        state.fileNamePattern = template.File_Name_Pattern__c;
        state.languages = template.Languages__c;
        state.defaultLanguage = template.Default_Language__c;
        state.activeVersionNumber = template.Active_Version__c == null ? null : template.Active_Version__r.Version_Number__c;

        DocTemplateVersion__c version = draftOf(templateId);
        if (version == null && template.Active_Version__c != null) {
            version = [SELECT Id, Version_Number__c, Status__c, Body_JSON__c FROM DocTemplateVersion__c WHERE Id = :template.Active_Version__c WITH USER_MODE];
        }
        if (version != null) {
            state.versionId = version.Id;
            state.versionNumber = version.Version_Number__c;
            state.versionStatus = version.Status__c;
            state.bodyJson = version.Body_JSON__c;
        }
        return state;
    }

    /** Saves into the current draft, or starts a new draft version when the latest version is active. */
    @AuraEnabled
    public static TemplateState saveDraft(Id templateId, String name, String fileNamePattern, String languages, String bodyJson) {
        try {
            JSON.deserializeUntyped(bodyJson);
            DocTemplate__c template = [SELECT Id, Active_Version__c FROM DocTemplate__c WHERE Id = :templateId WITH USER_MODE FOR UPDATE];
            if (String.isNotBlank(name)) {
                template.Name = name.trim().left(80);
            }
            template.File_Name_Pattern__c = fileNamePattern;
            template.Languages__c = languages;
            update as user template;

            DocTemplateVersion__c draft = draftOf(templateId);
            if (draft != null) {
                draft.Body_JSON__c = bodyJson;
                update as user draft;
            } else {
                AggregateResult latest = [SELECT MAX(Version_Number__c) maxVersion FROM DocTemplateVersion__c WHERE Template__c = :templateId WITH USER_MODE];
                Decimal nextNumber = latest.get('maxVersion') == null ? 1 : (Decimal) latest.get('maxVersion') + 1;
                draft = new DocTemplateVersion__c(Template__c = templateId, Version_Number__c = nextNumber, Status__c = 'Draft', Body_JSON__c = bodyJson);
                insert as user draft;
                // Carry translations forward so a new version does not start untranslated.
                if (template.Active_Version__c != null) {
                    List<DocTranslation__c> copies = new List<DocTranslation__c>();
                    for (DocTranslation__c t : [
                        SELECT Language__c, Block_Id__c, Part__c, Source_Text__c, Translated_Text__c
                        FROM DocTranslation__c
                        WHERE Template_Version__c = :template.Active_Version__c
                        WITH USER_MODE
                    ]) {
                        DocTranslation__c copy = t.clone(false, true);
                        copy.Template_Version__c = draft.Id;
                        copies.add(copy);
                    }
                    insert as user copies;
                }
            }
            return loadTemplate(templateId);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /** Makes the draft the active version. The previous active version is archived, never deleted. */
    @AuraEnabled
    public static TemplateState activate(Id templateId) {
        try {
            DocTemplate__c template = [SELECT Id, Base_Object__c, Active_Version__c FROM DocTemplate__c WHERE Id = :templateId WITH USER_MODE FOR UPDATE];
            DocTemplateVersion__c draft = draftOf(templateId);
            if (draft == null) {
                throw new DocBuilder.DocBuilderException('There is no draft to activate. Save a change first.');
            }
            String problem = check(draft.Body_JSON__c, template.Base_Object__c);
            if (problem != null) {
                throw new DocBuilder.DocBuilderException('This template cannot be activated yet. ' + problem);
            }
            List<DocTemplateVersion__c> changes = new List<DocTemplateVersion__c>();
            if (template.Active_Version__c != null) {
                changes.add(new DocTemplateVersion__c(Id = template.Active_Version__c, Status__c = 'Archived'));
            }
            changes.add(new DocTemplateVersion__c(Id = draft.Id, Status__c = 'Active', Activated_On__c = System.now()));
            update as user changes;
            template.Active_Version__c = draft.Id;
            template.Status__c = 'Active';
            update as user template;
            return loadTemplate(templateId);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    public class VersionInfo {
        @AuraEnabled
        public Id id;
        @AuraEnabled
        public Decimal versionNumber;
        @AuraEnabled
        public String status;
        @AuraEnabled
        public Datetime activatedOn;
        @AuraEnabled
        public Datetime lastModified;
        @AuraEnabled
        public String lastModifiedBy;
    }

    /** Every version of a template, newest first. */
    @AuraEnabled
    public static List<VersionInfo> listVersions(Id templateId) {
        List<VersionInfo> versions = new List<VersionInfo>();
        for (DocTemplateVersion__c v : [
            SELECT Id, Version_Number__c, Status__c, Activated_On__c, LastModifiedDate, LastModifiedBy.Name
            FROM DocTemplateVersion__c
            WHERE Template__c = :templateId
            WITH USER_MODE
            ORDER BY Version_Number__c DESC
            LIMIT 200
        ]) {
            VersionInfo info = new VersionInfo();
            info.id = v.Id;
            info.versionNumber = v.Version_Number__c;
            info.status = v.Status__c;
            info.activatedOn = v.Activated_On__c;
            info.lastModified = v.LastModifiedDate;
            info.lastModifiedBy = v.LastModifiedBy?.Name;
            versions.add(info);
        }
        return versions;
    }

    /** An error for the designer whose message also survives in tests (AuraHandledException hides it otherwise). */
    static AuraHandledException userError(Exception e) {
        AuraHandledException error = new AuraHandledException(e.getMessage());
        error.setMessage(e.getMessage());
        return error;
    }

    static DocTemplateVersion__c versionOf(Id templateId, Id versionId) {
        List<DocTemplateVersion__c> found = [
            SELECT Id, Version_Number__c, Status__c, Body_JSON__c
            FROM DocTemplateVersion__c
            WHERE Id = :versionId AND Template__c = :templateId
            WITH USER_MODE
        ];
        if (found.isEmpty()) {
            throw new DocBuilder.DocBuilderException('That version is not part of this template.');
        }
        return found[0];
    }

    /**
     * Puts an earlier version back in use straight away, for example to undo a change that went live by mistake.
     * The version that was live is archived (never deleted), and any draft is left as it is.
     */
    @AuraEnabled
    public static TemplateState makeVersionLive(Id templateId, Id versionId) {
        try {
            DocTemplate__c template = [SELECT Id, Base_Object__c, Active_Version__c FROM DocTemplate__c WHERE Id = :templateId WITH USER_MODE FOR UPDATE];
            DocTemplateVersion__c chosen = versionOf(templateId, versionId);
            if (chosen.Status__c == 'Draft') {
                throw new DocBuilder.DocBuilderException('Version ' + chosen.Version_Number__c + ' is the draft. Use Activate to put it live.');
            }
            if (chosen.Id == template.Active_Version__c) {
                throw new DocBuilder.DocBuilderException('Version ' + chosen.Version_Number__c + ' is already live.');
            }
            // Fields can be removed from the org after a version was archived, so check it still works before it goes live.
            String problem = check(chosen.Body_JSON__c, template.Base_Object__c);
            if (problem != null) {
                throw new DocBuilder.DocBuilderException('Version ' + chosen.Version_Number__c + ' cannot be put live. ' + problem);
            }
            List<DocTemplateVersion__c> changes = new List<DocTemplateVersion__c>();
            if (template.Active_Version__c != null) {
                changes.add(new DocTemplateVersion__c(Id = template.Active_Version__c, Status__c = 'Archived'));
            }
            changes.add(new DocTemplateVersion__c(Id = chosen.Id, Status__c = 'Active', Activated_On__c = System.now()));
            update as user changes;
            template.Active_Version__c = chosen.Id;
            template.Status__c = 'Active';
            update as user template;
            return loadTemplate(templateId);
        } catch (Exception e) {
            throw userError(e);
        }
    }

    /**
     * Copies an earlier version, with its translations, into the draft so it can be changed and activated later.
     * Replaces the current draft's content if there is one; otherwise starts a new draft version.
     */
    @AuraEnabled
    public static TemplateState copyVersionToDraft(Id templateId, Id versionId) {
        try {
            DocTemplateVersion__c source = versionOf(templateId, versionId);
            if (source.Status__c == 'Draft') {
                throw new DocBuilder.DocBuilderException('Version ' + source.Version_Number__c + ' is already the draft.');
            }
            DocTemplateVersion__c draft = draftOf(templateId);
            if (draft != null) {
                draft.Body_JSON__c = source.Body_JSON__c;
                update as user draft;
                delete as user [SELECT Id FROM DocTranslation__c WHERE Template_Version__c = :draft.Id WITH USER_MODE];
            } else {
                AggregateResult latest = [SELECT MAX(Version_Number__c) maxVersion FROM DocTemplateVersion__c WHERE Template__c = :templateId WITH USER_MODE];
                draft = new DocTemplateVersion__c(
                    Template__c = templateId,
                    Version_Number__c = (Decimal) latest.get('maxVersion') + 1,
                    Status__c = 'Draft',
                    Body_JSON__c = source.Body_JSON__c
                );
                insert as user draft;
            }
            List<DocTranslation__c> copies = new List<DocTranslation__c>();
            for (DocTranslation__c t : [
                SELECT Language__c, Block_Id__c, Part__c, Source_Text__c, Translated_Text__c
                FROM DocTranslation__c
                WHERE Template_Version__c = :source.Id
                WITH USER_MODE
            ]) {
                DocTranslation__c copy = t.clone(false, true);
                copy.Template_Version__c = draft.Id;
                copies.add(copy);
            }
            insert as user copies;
            return loadTemplate(templateId);
        } catch (Exception e) {
            throw userError(e);
        }
    }

    static DocTemplateVersion__c draftOf(Id templateId) {
        List<DocTemplateVersion__c> drafts = [
            SELECT Id, Version_Number__c, Status__c, Body_JSON__c
            FROM DocTemplateVersion__c
            WHERE Template__c = :templateId AND Status__c = 'Draft'
            WITH USER_MODE
            ORDER BY Version_Number__c DESC
            LIMIT 1
        ];
        return drafts.isEmpty() ? null : drafts[0];
    }

    static Schema.DescribeSObjectResult describe(String objectName) {
        try {
            return Schema.describeSObjects(new List<String>{ objectName.trim() })[0];
        } catch (Exception e) {
            throw new DocBuilder.DocBuilderException('"' + objectName + '" is not an object in this org. Use its API name, for example Opportunity.');
        }
    }

    /** Fields and child lists of an object, limited to what the current user can read. */
    @AuraEnabled(cacheable=true)
    public static ObjectInfo describeObject(String objectName) {
        try {
            Schema.DescribeSObjectResult described = describe(objectName);
            ObjectInfo info = new ObjectInfo();
            info.name = described.getName();
            info.label = described.getLabel();
            for (Schema.SObjectField f : described.fields.getMap().values()) {
                Schema.DescribeFieldResult d = f.getDescribe();
                if (!d.isAccessible()) {
                    continue;
                }
                FieldInfo field = new FieldInfo();
                field.name = d.getName();
                field.label = d.getLabel();
                field.type = String.valueOf(d.getType()).toLowerCase().capitalize();
                if (d.getType() == Schema.DisplayType.REFERENCE && d.getRelationshipName() != null && !d.getReferenceTo().isEmpty()) {
                    field.relationshipName = d.getRelationshipName();
                    field.referenceTo = String.valueOf(d.getReferenceTo()[0]);
                }
                if (d.getType() == Schema.DisplayType.PICKLIST || d.getType() == Schema.DisplayType.MULTIPICKLIST) {
                    field.values = new List<String>();
                    for (Schema.PicklistEntry entry : d.getPicklistValues()) {
                        if (entry.isActive() && field.values.size() < 300) {
                            field.values.add(entry.getValue());
                        }
                    }
                }
                info.fields.add(field);
            }
            for (Schema.ChildRelationship rel : described.getChildRelationships()) {
                if (rel.getRelationshipName() == null) {
                    continue;
                }
                ChildInfo child = new ChildInfo();
                child.name = rel.getRelationshipName();
                child.childObject = String.valueOf(rel.getChildSObject());
                child.label = rel.getChildSObject().getDescribe().getLabelPlural();
                child.field = String.valueOf(rel.getField());
                info.children.add(child);
            }
            return info;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    @AuraEnabled
    public static String preview(String bodyJson, String baseObject, Id recordId, Id versionId, String language) {
        try {
            return DocBuilderEngine.previewHtml(bodyJson, baseObject, recordId, versionId, language);
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    public class CalcResult {
        @AuraEnabled
        public Boolean ok;
        /** Calculated value name -> its value as it would print. */
        @AuraEnabled
        public Map<String, String> values = new Map<String, String>();
        @AuraEnabled
        public String message;
    }

    /** Works out every calculated value of an unsaved template for one record, for the live result next to a formula. */
    @AuraEnabled
    public static CalcResult calcValues(String bodyJson, String baseObject, Id recordId) {
        CalcResult result = new CalcResult();
        try {
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(bodyJson);
            DocBuilderContext ctx = new DocBuilderContext(baseObject, recordId, body, null);
            ctx.load();
            for (String name : ctx.calcs.keySet()) {
                result.values.put(name, ctx.formatCalc(name, null));
            }
            result.ok = true;
        } catch (Exception e) {
            result.ok = false;
            result.message = e.getMessage();
        }
        return result;
    }

    /** Every signature provider row with whether it is switched on. */
    @AuraEnabled
    public static List<DocBuilderSign.ProviderStatus> listProviders() {
        return DocBuilderSign.allProviders();
    }

    public class ConnectionResult {
        @AuraEnabled
        public Boolean ok;
        @AuraEnabled
        public String message;
    }

    /**
     * Tries a provider's connection without sending anything. Admin-only (this class is only in the
     * DocBuilder Admin permission set), so the provider's own error text is shown to help set-up.
     */
    @AuraEnabled
    public static ConnectionResult testProvider(String providerName) {
        ConnectionResult result = new ConnectionResult();
        try {
            result.message = DocBuilderSign.testConnection(providerName);
            result.ok = true;
        } catch (DocBuilderSignHttp.ProviderException e) {
            result.ok = false;
            result.message = e.getMessage() + (e.detail == null ? '' : ' ' + e.detail.left(300));
        } catch (Exception e) {
            result.ok = false;
            result.message = e.getMessage();
        }
        return result;
    }

    /** Health check: returns null when every field, data source and custom block the template uses works, otherwise the problem. */
    @AuraEnabled
    public static String check(String bodyJson, String baseObject) {
        try {
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(bodyJson);
            DocBuilderPrepare.apply(body, null, null);
            DocBuilderContext ctx = new DocBuilderContext(baseObject, null, body, null);
            String problem = ctx.check();
            if (problem == null) {
                problem = ctx.checkApexChecks();
            }
            return problem != null ? problem : checkCustomBlocks(body);
        } catch (Exception e) {
            return e.getMessage();
        }
    }

    static String checkCustomBlocks(Map<String, Object> body) {
        for (Object b : DocBuilderContext.asList(body.get('blocks'))) {
            Map<String, Object> blk = (Map<String, Object>) b;
            if (blk.get('type') != 'custom') {
                continue;
            }
            if (blk.get('source') == 'visualforce') {
                String page = (String) blk.get('page');
                if (String.isBlank(page)) {
                    return 'A Custom content block has no Visualforce page chosen.';
                }
                if ([SELECT COUNT() FROM ApexPage WHERE Name = :page.trim() WITH USER_MODE] == 0) {
                    return 'The Visualforce page "' + page + '" does not exist in this org.';
                }
            } else {
                String className = (String) blk.get('className');
                String problem = String.isBlank(className) ? 'A Custom content block has no Apex class chosen.' : DocBuilderRenderer.checkContentProvider(className);
                if (problem != null) {
                    return problem;
                }
            }
        }
        return null;
    }

    public class Choice {
        @AuraEnabled
        public String label;
        @AuraEnabled
        public String value;
        Choice(String label, String value) {
            this.label = label;
            this.value = value;
        }
    }

    static final Pattern NOISE_OBJECTS = Pattern.compile('(?i).*(Share|History|Feed|ChangeEvent|Tag|__mdt|__e|__x|__b)$');

    /** Objects the current user can query, for a data source's "Records of" list. */
    @AuraEnabled(cacheable=true)
    public static List<Choice> listObjects() {
        List<Choice> choices = new List<Choice>();
        for (Schema.SObjectType t : Schema.getGlobalDescribe().values()) {
            Schema.DescribeSObjectResult d = t.getDescribe(SObjectDescribeOptions.DEFERRED);
            if (!d.isQueryable() || !d.isAccessible() || d.isCustomSetting() || NOISE_OBJECTS.matcher(d.getName()).matches()) {
                continue;
            }
            choices.add(new Choice(d.getLabel() + ' (' + d.getName() + ')', d.getName()));
        }
        choices.sort(new ChoiceOrder());
        return choices;
    }

    class ChoiceOrder implements Comparator<Choice> {
        public Integer compare(Choice a, Choice b) {
            return a.label.toLowerCase().compareTo(b.label.toLowerCase());
        }
    }

    /** Visualforce pages in the org, for a Custom content block. */
    @AuraEnabled(cacheable=true)
    public static List<Choice> listVisualforcePages() {
        List<Choice> choices = new List<Choice>();
        for (ApexPage p : [SELECT Name, MasterLabel, NamespacePrefix FROM ApexPage WITH USER_MODE ORDER BY MasterLabel LIMIT 1000]) {
            String name = String.isBlank(p.NamespacePrefix) ? p.Name : p.NamespacePrefix + '__' + p.Name;
            choices.add(new Choice(p.MasterLabel + ' (' + name + ')', name));
        }
        return choices;
    }

    /**
     * Saves a diagonal watermark image drawn by the designer (a PNG with the words at 45 degrees), attached to the
     * template so everyone who can see the template can print it. Returns the ContentVersion Id.
     */
    @AuraEnabled
    public static Id saveWatermarkImage(Id templateId, String base64Png) {
        try {
            DocTemplate__c template = [SELECT Id FROM DocTemplate__c WHERE Id = :templateId WITH USER_MODE];
            if (String.isBlank(base64Png) || base64Png.length() > 2000000) {
                throw new DocBuilder.DocBuilderException('The watermark image is empty or too large.');
            }
            Blob image = EncodingUtil.base64Decode(base64Png);
            // Only a PNG is accepted: its first bytes are always 89 50 4E 47.
            if (!EncodingUtil.convertToHex(image).startsWith('89504e47')) {
                throw new DocBuilder.DocBuilderException('The watermark image is not a PNG.');
            }
            ContentVersion file = new ContentVersion(Title = 'DocBuilder watermark', PathOnClient = 'watermark.png', VersionData = image, FirstPublishLocationId = template.Id);
            insert as user file;
            return file.Id;
        } catch (Exception e) {
            throw userError(e);
        }
    }

    /** Null when the Apex class can be used for Apex variables, otherwise why not. */
    @AuraEnabled
    public static String checkConditionClass(String className) {
        try {
            DocBuilderContext.apexProvider(className);
            return null;
        } catch (Exception e) {
            return e.getMessage();
        }
    }

    public class ApexClassInfo {
        @AuraEnabled
        public Boolean ok;
        @AuraEnabled
        public String message;
        /** 'values' for a DocBuilderVariableProvider, 'check' for a yes/no DocBuilderConditionProvider. */
        @AuraEnabled
        public String kind;
        @AuraEnabled
        public List<Choice> variables = new List<Choice>();
    }

    /** What an Apex class offers to Apex variables: its named values and their types, or a single yes/no. */
    @AuraEnabled
    public static ApexClassInfo describeApexClass(String className) {
        ApexClassInfo info = new ApexClassInfo();
        try {
            Map<String, String> offered = DocBuilderContext.variablesOf(className);
            info.ok = true;
            info.kind = offered == null ? 'check' : 'values';
            if (offered != null) {
                List<String> names = new List<String>(offered.keySet());
                names.sort();
                for (String name : names) {
                    // The label carries the type so the designer can offer matching comparisons.
                    info.variables.add(new Choice(String.isBlank(offered.get(name)) ? 'Text' : offered.get(name), name));
                }
            }
        } catch (Exception e) {
            info.ok = false;
            info.message = e.getMessage();
        }
        return info;
    }

    /** Null when the Apex class can be used in a Custom content block, otherwise why not. */
    @AuraEnabled
    public static String checkContentClass(String className) {
        return DocBuilderRenderer.checkContentProvider(className);
    }

    @AuraEnabled
    public static List<DocBuilderPrepare.TextPart> getTranslations(Id versionId, String language) {
        DocTemplateVersion__c version = [SELECT Body_JSON__c FROM DocTemplateVersion__c WHERE Id = :versionId WITH USER_MODE];
        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(version.Body_JSON__c);
        return DocBuilderPrepare.parts(body, versionId, language);
    }

    /** Replaces the translations of one version and language. itemsJson is a list of { blockId, part, source, translated }. */
    @AuraEnabled
    public static void saveTranslations(Id versionId, String language, String itemsJson) {
        try {
            if (String.isBlank(language)) {
                throw new DocBuilder.DocBuilderException('Choose a language first.');
            }
            delete as user [SELECT Id FROM DocTranslation__c WHERE Template_Version__c = :versionId AND Language__c = :language WITH USER_MODE];
            List<DocTranslation__c> rows = new List<DocTranslation__c>();
            for (Object o : (List<Object>) JSON.deserializeUntyped(itemsJson)) {
                Map<String, Object> item = (Map<String, Object>) o;
                String translated = (String) item.get('translated');
                if (String.isBlank(translated)) {
                    continue;
                }
                rows.add(
                    new DocTranslation__c(
                        Template_Version__c = versionId,
                        Language__c = language.trim().left(10),
                        Block_Id__c = (String) item.get('blockId'),
                        Part__c = (String) item.get('part'),
                        Source_Text__c = (String) item.get('source'),
                        Translated_Text__c = translated
                    )
                );
            }
            insert as user rows;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }
}
