@IsTest
private class DocBuilderDesignerTest {
    static Map<String, Object> cond(String field, String op, Object value) {
        return new Map<String, Object>{ 'field' => field, 'op' => op, 'value' => value };
    }

    static Opportunity makeData() {
        Account acct = new Account(Name = 'Harbor Sample Co', Industry = 'Logistics');
        insert acct;
        insert new List<Contact>{ new Contact(AccountId = acct.Id, LastName = 'Nair'), new Contact(AccountId = acct.Id, LastName = 'Rivera') };
        Opportunity opp = new Opportunity(AccountId = acct.Id, Name = 'Deal B', StageName = 'Prospecting', CloseDate = Date.today().addDays(30), Amount = 3000);
        insert opp;
        return opp;
    }

    static String oppBody(String netExpression) {
        List<Object> blocks = new List<Object>{
            new Map<String, Object>{ 'id' => 'intro', 'type' => 'text', 'text' => 'Hello {{Account.Name}} net {{calc:Net|currency}}' },
            new Map<String, Object>{
                'id' => 'people',
                'type' => 'table',
                'source' => 'Account.Contacts',
                'orderBy' => 'LastName',
                'columns' => new List<Object>{ new Map<String, Object>{ 'header' => 'Surname', 'field' => 'LastName' } },
                'totals' => new List<Object>{ new Map<String, Object>{ 'label' => 'People', 'calc' => 'People' } }
            },
            new Map<String, Object>{
                'id' => 'terms',
                'type' => 'terms',
                'title' => 'Terms',
                'clauseCategory' => 'Standard',
                'items' => new List<Object>{ new Map<String, Object>{ 'id' => 'inline', 'text' => 'INLINE-CLAUSE' } }
            }
        };
        List<Object> calculations = new List<Object>{
            new Map<String, Object>{ 'name' => 'People', 'type' => 'count', 'source' => 'Account.Contacts' },
            new Map<String, Object>{ 'name' => 'Half', 'type' => 'formula', 'expression' => 'Amount / 2' },
            new Map<String, Object>{ 'name' => 'Net', 'type' => 'formula', 'expression' => netExpression }
        };
        return JSON.serialize(new Map<String, Object>{ 'blocks' => blocks, 'calculations' => calculations });
    }

    static void becomeAdmin() {
        User me = new User(Id = UserInfo.getUserId());
        PermissionSet adminSet = [SELECT Id FROM PermissionSet WHERE Name = 'DocBuilder_Admin'];
        if ([SELECT COUNT() FROM PermissionSetAssignment WHERE AssigneeId = :me.Id AND PermissionSetId = :adminSet.Id] == 0) {
            System.runAs(me) {
                insert new PermissionSetAssignment(AssigneeId = me.Id, PermissionSetId = adminSet.Id);
            }
        }
    }

    static String fileText(Id contentVersionId) {
        return [SELECT VersionData FROM ContentVersion WHERE Id = :contentVersionId].VersionData.toString();
    }

    @IsTest
    static void clausesTranslationsFormulasParentListsAndPacks() {
        Opportunity opp = makeData();
        DocClause__c pay = new DocClause__c(Name = 'Pay', Category__c = 'Standard', Text__c = 'LIB-PAY for {{Name}}', Sort_Order__c = 1);
        insert new List<DocClause__c>{
            pay,
            new DocClause__c(
                Name = 'Never',
                Category__c = 'Standard',
                Text__c = 'LIB-NEVER',
                Sort_Order__c = 2,
                Rule_JSON__c = JSON.serialize(new Map<String, Object>{ 'conditions' => new List<Object>{ cond('Amount', 'gt', 99999) } })
            ),
            new DocClause__c(Name = 'Old', Category__c = 'Standard', Text__c = 'LIB-INACTIVE', Active__c = false),
            new DocClause__c(Name = 'Other', Category__c = 'Legal', Text__c = 'LIB-OTHER-CATEGORY')
        };
        Id mainId = DocBuilderSamples.createTemplate('Opp Pack', 'Opportunity', 'Pack {{Name}}', oppBody('calc:Half * (1 + 1) - 100.5'));
        Id secondId = DocBuilderSamples.createTemplate('Second', 'Opportunity', null, '{"blocks":[{"id":"s","type":"text","text":"SECOND-PART"}]}');
        update new DocTemplate__c(Id = mainId, Default_Language__c = 'en', Languages__c = 'en, fr');
        Id versionId = [SELECT Active_Version__c FROM DocTemplate__c WHERE Id = :mainId].Active_Version__c;
        insert new List<DocTranslation__c>{
            new DocTranslation__c(Template_Version__c = versionId, Language__c = 'fr', Block_Id__c = 'intro', Part__c = 'text', Translated_Text__c = 'Bonjour {{Account.Name}}'),
            new DocTranslation__c(Template_Version__c = versionId, Language__c = 'fr', Block_Id__c = 'people', Part__c = 'col:0', Translated_Text__c = 'Nom'),
            new DocTranslation__c(Template_Version__c = versionId, Language__c = 'fr', Block_Id__c = 'terms', Part__c = 'item:inline', Translated_Text__c = 'CLAUSE-FR'),
            new DocTranslation__c(Clause__c = pay.Id, Language__c = 'fr', Translated_Text__c = 'LIB-PAYER')
        };

        // Default language
        DocBuilder.Request req = new DocBuilder.Request();
        req.templateId = mainId;
        req.recordId = opp.Id;
        req.language = 'en';
        DocBuilder.Result res = DocBuilder.generate(req);
        System.assert(res.success, res.errorMessage);
        String html = fileText(res.contentVersionId);
        System.assert(html.contains('Hello Harbor Sample Co'), html);
        System.assert(html.contains('2,899.50'), 'Formula should give 3000 / 2 * 2 - 100.5');
        System.assert(html.contains('Surname') && html.contains('Nair') && html.contains('Rivera'), 'Contacts come from the parent account');
        System.assert(html.contains('INLINE-CLAUSE') && html.contains('LIB-PAY for Deal B'));
        System.assert(!html.contains('LIB-NEVER') && !html.contains('LIB-INACTIVE') && !html.contains('LIB-OTHER-CATEGORY'));
        System.assert(!html.contains('DRAFT'));

        // French, draft, two templates combined, emailed
        req.language = 'fr';
        req.draft = true;
        req.additionalTemplateIds = new List<Id>{ secondId };
        req.emailTo = new List<String>{ 'someone@example.com' };
        res = DocBuilder.generate(req);
        System.assert(res.success, res.errorMessage);
        System.assertEquals('Pack Deal B - DRAFT.pdf', res.fileName);
        html = fileText(res.contentVersionId);
        System.assert(html.contains('Bonjour Harbor Sample Co') && html.contains('Nom'), html);
        System.assert(html.contains('CLAUSE-FR') && html.contains('LIB-PAYER'));
        System.assert(html.contains('DRAFT') && html.contains('SECOND-PART'));

        GeneratedDocument__c doc = [SELECT Language__c, Is_Draft__c, Snapshot_JSON__c, (SELECT Type__c FROM Deliveries__r) FROM GeneratedDocument__c WHERE Id = :res.documentId];
        System.assertEquals('fr', doc.Language__c);
        System.assert(doc.Is_Draft__c);
        System.assertEquals(2, doc.Deliveries__r.size());
        System.assert(doc.Snapshot_JSON__c.startsWith('{"parts"'));

        // Broken formulas fail cleanly
        for (String broken : new List<String>{ 'Amount +', '(Amount', 'Amount $ 2', 'calc:Missing + 1', 'Name * 2', '' }) {
            Id badId = DocBuilderSamples.createTemplate('Bad ' + broken.length(), 'Opportunity', null, oppBody(broken));
            DocBuilder.Request bad = new DocBuilder.Request();
            bad.templateId = badId;
            bad.recordId = opp.Id;
            DocBuilder.Result failed = DocBuilder.generate(bad);
            System.assertEquals(false, failed.success, 'Expected "' + broken + '" to fail');
        }
    }

    @IsTest
    static void pageSetupHeaderFooterWatermarkImagesAndRichText() {
        Opportunity opp = makeData();
        Map<String, Object> page = new Map<String, Object>{
            'size' => 'A4',
            'orientation' => 'landscape',
            'margin' => 'narrow',
            'header' => new Map<String, Object>{ 'text' => 'HEAD {{Account.Name}}', 'logoId' => '068000000000001AAA', 'logoWidth' => '90' },
            'footer' => new Map<String, Object>{ 'text' => 'FOOT {{Name}}', 'pageNumbers' => true },
            'watermark' => new Map<String, Object>{
                'text' => 'CONFIDENTIAL',
                'showIf' => new Map<String, Object>{ 'conditions' => new List<Object>{ cond('Amount', 'gt', 1000) } }
            }
        };
        List<Object> blocks = new List<Object>{
            new Map<String, Object>{
                'id' => 'r',
                'type' => 'text',
                'rich' => true,
                'align' => 'center',
                'text' => '<p><strong>Dear</strong> {{Account.Name}}<br><script>alert(1)</script><span onclick="x()" style="color: red;">red</span> <a href="javascript:alert(2)">link</a></p>'
            },
            new Map<String, Object>{ 'id' => 'i', 'type' => 'image', 'contentVersionId' => '068000000000002AAA', 'width' => 300, 'align' => 'right' },
            new Map<String, Object>{ 'id' => 'bad', 'type' => 'image', 'contentVersionId' => '"><script>' }
        };
        String body = JSON.serialize(new Map<String, Object>{ 'blocks' => blocks, 'page' => page });
        Id templateId = DocBuilderSamples.createTemplate('Paged', 'Opportunity', null, body);

        DocBuilder.Request req = new DocBuilder.Request();
        req.templateId = templateId;
        req.recordId = opp.Id;
        DocBuilder.Result res = DocBuilder.generate(req);
        System.assert(res.success, res.errorMessage);
        String html = fileText(res.contentVersionId);
        System.assert(html.contains('@page{size:A4 landscape;margin:26mm 12mm 22mm 12mm;'), html);
        System.assert(html.contains('@top-center{content:element(dbheader)}') && html.contains('@bottom-center{content:element(dbfooter)}'));
        System.assert(html.contains('HEAD Harbor Sample Co') && html.contains('FOOT Deal B'));
        System.assert(html.contains('version/download/068000000000001AAA" style="width:90px"'), 'Header logo');
        System.assert(html.contains('class="pagenumber"'));
        System.assert(html.contains('CONFIDENTIAL'), 'Amount is above 1000 so the watermark prints');
        System.assert(html.contains('<strong>Dear</strong> Harbor Sample Co<br/>'), 'Rich formatting is kept and tokens are merged');
        System.assert(!html.contains('<script') && !html.contains('onclick') && !html.contains('javascript:'), 'Unsafe markup is removed');
        System.assert(html.contains('class="img right"') && html.contains('068000000000002AAA" style="width:300px"'));
        System.assert(html.contains('class="rich center"'));

        // Letter portrait, default margins, watermark rule not met
        page.put('size', 'Letter');
        page.put('orientation', 'portrait');
        page.remove('margin');
        opp.Amount = 500;
        update opp;
        String preview = DocBuilderEngine.previewHtml(JSON.serialize(new Map<String, Object>{ 'blocks' => blocks, 'page' => page }), 'Opportunity', opp.Id, null, null);
        System.assert(preview.contains('pv-header') && preview.contains('pv-footer') && preview.contains('Page 1'));
        System.assert(!preview.contains('CONFIDENTIAL'), 'Amount is now below the watermark threshold');

        Id letterId = DocBuilderSamples.createTemplate('Letter', 'Opportunity', null, JSON.serialize(new Map<String, Object>{ 'blocks' => blocks, 'page' => page }));
        req.templateId = letterId;
        res = DocBuilder.generate(req);
        System.assert(fileText(res.contentVersionId).contains('@page{size:8.5in 11in;margin:34mm 20mm 30mm 20mm;'));

        List<DocBuilderPrepare.TextPart> parts = DocBuilderPrepare.parts((Map<String, Object>) JSON.deserializeUntyped(body), null, null);
        Set<String> names = new Set<String>();
        for (DocBuilderPrepare.TextPart p : parts) {
            names.add(p.blockId + '|' + p.part);
        }
        System.assert(names.contains('page|header') && names.contains('page|footer') && names.contains('page|watermark'), 'Page text is translatable');
    }

    @IsTest
    static void bulkJobGeneratesOneDocumentPerRecord() {
        Opportunity opp = makeData();
        Opportunity other = new Opportunity(AccountId = opp.AccountId, Name = 'Deal C', StageName = 'Prospecting', CloseDate = Date.today(), Amount = 10);
        insert other;
        DocBuilderSamples.createTemplate('Bulk Letter', 'Opportunity', 'Letter {{Name}}', '{"blocks":[{"id":"a","type":"text","text":"For {{Name}}"}]}');

        Test.startTest();
        Id jobId = DocBuilder.generateInBackground('Bulk Letter', new List<Id>{ opp.Id, other.Id, opp.AccountId });
        Test.stopTest();

        DocGenJob__c job = [SELECT Status__c, Total__c, Succeeded__c, Failed__c, Finished_On__c FROM DocGenJob__c WHERE Id = :jobId];
        System.assertEquals('Done', job.Status__c);
        System.assertEquals(3, job.Total__c);
        System.assertEquals(2, job.Succeeded__c);
        System.assertEquals(1, job.Failed__c, 'The account is the wrong object and must be counted as failed');
        System.assertEquals(3, [SELECT COUNT() FROM GeneratedDocument__c WHERE Job__c = :jobId AND Channel__c = 'Bulk']);

        try {
            DocBuilder.generateInBackground('Bulk Letter', new List<Id>());
            System.assert(false);
        } catch (DocBuilder.DocBuilderException e) {
            System.assert(e.getMessage().contains('required'));
        }
    }

    @IsTest
    static void designerLifecycle() {
        Opportunity opp = makeData();
        becomeAdmin();

        try {
            DocBuilderDesignerController.createTemplate('Nope', 'Not_An_Object__x');
            System.assert(false);
        } catch (AuraHandledException e) {
            System.assert(true);
        }

        DocBuilderDesignerController.TemplateState state = DocBuilderDesignerController.createTemplate('Designer Quote', 'opportunity');
        System.assertEquals('Opportunity', state.baseObject);
        System.assertEquals('Draft', state.versionStatus);
        System.assertEquals(1, state.versionNumber);
        System.assertEquals(1, DocBuilderDesignerController.listTemplates().size());

        DocBuilderDesignerController.ObjectInfo info = DocBuilderDesignerController.describeObject('Opportunity');
        System.assert(info.fields.size() > 5);
        Boolean hasAccountLookup = false;
        for (DocBuilderDesignerController.FieldInfo f : info.fields) {
            hasAccountLookup = hasAccountLookup || (f.relationshipName == 'Account' && f.referenceTo == 'Account');
        }
        System.assert(hasAccountLookup);
        Boolean hasLineItems = false;
        for (DocBuilderDesignerController.ChildInfo c : info.children) {
            hasLineItems = hasLineItems || c.name == 'OpportunityLineItems';
        }
        System.assert(hasLineItems);

        String body = oppBody('calc:Half + 1');
        System.assertEquals(null, DocBuilderDesignerController.check(body, 'Opportunity'));
        System.assertNotEquals(null, DocBuilderDesignerController.check('{"blocks":[{"type":"text","text":"{{Not_A_Field__c}}"}]}', 'Opportunity'));
        System.assertNotEquals(null, DocBuilderDesignerController.check('not json', 'Opportunity'));

        state = DocBuilderDesignerController.saveDraft(state.templateId, 'Designer Quote 2', 'Q {{Name}}', 'en, fr', body);
        System.assertEquals('Designer Quote 2', state.name);
        System.assertEquals(1, state.versionNumber, 'Saving a draft again must not create a new version');

        String html = DocBuilderDesignerController.preview(body, 'Opportunity', opp.Id, state.versionId, null);
        System.assert(html.contains('Hello Harbor Sample Co') && html.contains('Nair'));

        DocBuilderDesignerController.saveTranslations(
            state.versionId,
            'fr',
            JSON.serialize(
                new List<Object>{
                    new Map<String, Object>{ 'blockId' => 'intro', 'part' => 'text', 'source' => 'An older wording', 'translated' => 'Bonjour {{Account.Name}}' },
                    new Map<String, Object>{ 'blockId' => 'people', 'part' => 'col:0', 'source' => 'Surname', 'translated' => '' }
                }
            )
        );
        List<DocBuilderPrepare.TextPart> parts = DocBuilderDesignerController.getTranslations(state.versionId, 'fr');
        System.assert(parts.size() >= 5, 'intro text, column heading, summary label, terms title, inline clause');
        System.assertEquals('Bonjour {{Account.Name}}', parts[0].translated);
        System.assert(parts[0].outOfDate, 'Source text changed since it was translated');

        state = DocBuilderDesignerController.activate(state.templateId);
        System.assertEquals('Active', state.status);
        System.assertEquals('Active', state.versionStatus);
        Id firstVersion = state.versionId;

        try {
            DocBuilderDesignerController.activate(state.templateId);
            System.assert(false, 'Activating without a draft should fail');
        } catch (AuraHandledException e) {
            System.assert(true);
        }

        state = DocBuilderDesignerController.saveDraft(state.templateId, null, null, 'en, fr', body);
        System.assertEquals(2, state.versionNumber, 'Editing an active template starts a new draft version');
        System.assertEquals(1, state.activeVersionNumber);
        System.assertEquals(1, [SELECT COUNT() FROM DocTranslation__c WHERE Template_Version__c = :state.versionId], 'Translations are carried forward');

        DocBuilder.Request req = new DocBuilder.Request();
        req.templateId = state.templateId;
        req.recordId = opp.Id;
        req.language = 'fr';
        DocBuilder.Result res = DocBuilder.generate(req);
        System.assert(res.success, res.errorMessage);
        System.assert(fileText(res.contentVersionId).contains('Bonjour Harbor Sample Co'), 'Users keep generating from the active version while a draft exists');

        state = DocBuilderDesignerController.activate(state.templateId);
        System.assertEquals(2, state.activeVersionNumber);
        System.assertEquals('Archived', [SELECT Status__c FROM DocTemplateVersion__c WHERE Id = :firstVersion].Status__c);

        try {
            DocBuilderDesignerController.saveDraft(state.templateId, null, null, null, 'not json');
            System.assert(false);
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        try {
            DocBuilderDesignerController.preview('{"blocks":[{"type":"text","text":"{{Nope__c}}"}]}', 'Opportunity', opp.Id, null, null);
            System.assert(false);
        } catch (AuraHandledException e) {
            System.assert(true);
        }
        try {
            DocBuilderDesignerController.saveTranslations(state.versionId, '', '[]');
            System.assert(false);
        } catch (AuraHandledException e) {
            System.assert(true);
        }
    }
}
