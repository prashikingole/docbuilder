@IsTest
private class DocBuilderDesignerTest {
    @TestSetup
    static void grantPermissions() {
        DocBuilderTestUtil.grantAdmin();
    }

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
    static void formulaFunctionsTableTotalsWidthsAndLiveResults() {
        Account acct = new Account(Name = 'Harbor Sample Co');
        insert acct;
        insert new List<Contact>{
            new Contact(AccountId = acct.Id, LastName = 'Nair', Department = 'Operations'),
            new Contact(AccountId = acct.Id, LastName = 'Rivera', Department = 'Technology')
        };
        Opportunity opp = new Opportunity(AccountId = acct.Id, Name = 'Deal F', StageName = 'Prospecting', CloseDate = Date.today(), Amount = 3000);
        insert opp;

        List<Object> calculations = new List<Object>{
            new Map<String, Object>{ 'name' => 'AllPeople', 'type' => 'count', 'source' => 'Account.Contacts' },
            new Map<String, Object>{ 'name' => 'Big', 'type' => 'formula', 'expression' => 'IF(Amount >= 1000, ROUND(Amount * 0.12345, 2), 0)' },
            new Map<String, Object>{ 'name' => 'Mx', 'type' => 'formula', 'expression' => 'MAX(1, calc:Big, 5) + MIN(2, ABS(-7)) + CEILING(1.2) + FLOOR(1.8)' },
            new Map<String, Object>{ 'name' => 'Logic', 'type' => 'formula', 'expression' => 'AND(1, NOT(0), OR(0, Amount != 3000, Amount = 3000)) + (Amount < 10)' }
        };
        List<Object> blocks = new List<Object>{
            new Map<String, Object>{ 'id' => 't', 'type' => 'text', 'text' => 'V {{calc:Big}} {{calc:Mx}} {{calc:Logic}} {{calc:AllPeople}}' },
            new Map<String, Object>{
                'id' => 'ops',
                'type' => 'table',
                'source' => 'Account.Contacts',
                'columns' => new List<Object>{ new Map<String, Object>{ 'header' => 'Name', 'field' => 'LastName' } },
                'rowFilter' => new Map<String, Object>{ 'conditions' => new List<Object>{ cond('Department', 'eq', 'Operations') } },
                'totals' => new List<Object>{ new Map<String, Object>{ 'label' => 'Shown', 'calc' => 'AllPeople' } }
            },
            new Map<String, Object>{ 'id' => 'l', 'type' => 'text', 'text' => 'L', 'span' => 40 },
            new Map<String, Object>{ 'id' => 'r', 'type' => 'text', 'text' => 'R', 'span' => 60, 'beside' => true }
        };
        String body = JSON.serialize(new Map<String, Object>{ 'blocks' => blocks, 'calculations' => calculations });
        String html = DocBuilderEngine.previewHtml(body, 'Opportunity', opp.Id, null, null);
        System.assert(html.contains('V 370.35 375.35 1 2'), html);
        System.assert(html.contains('Shown 1</td>'), 'A total under a filtered table counts only the rows it shows: ' + html);
        System.assert(html.contains('width:40%') && html.contains('width:60%'), 'Widths set by dragging are kept');

        DocBuilderDesignerController.CalcResult live = DocBuilderDesignerController.calcValues(body, 'Opportunity', opp.Id);
        System.assert(live.ok, live.message);
        System.assertEquals('370.35', live.values.get('Big'));
        System.assertEquals('2', live.values.get('AllPeople'));

        for (String broken : new List<String>{ 'FOO(1)', 'ROUND(1, 2, 3)', 'IF(1, 2)', 'MAX()', 'ROUND(1,', 'Amount > ', '1, 2' }) {
            calculations[1] = new Map<String, Object>{ 'name' => 'Big', 'type' => 'formula', 'expression' => broken };
            DocBuilderDesignerController.CalcResult bad = DocBuilderDesignerController.calcValues(
                JSON.serialize(new Map<String, Object>{ 'blocks' => new List<Object>(), 'calculations' => calculations }),
                'Opportunity',
                opp.Id
            );
            System.assertEquals(false, bad.ok, 'Expected "' + broken + '" to fail');
        }

        // Deep nesting fails with a clear message instead of an uncatchable stack overflow; normal nesting still works.
        String deepBrackets = '('.repeat(300) + '1' + ')'.repeat(300);
        String deepMinus = '-'.repeat(300) + '1';
        String deepCalls = 'ABS('.repeat(300) + '1' + ')'.repeat(300);
        for (String deep : new List<String>{ deepBrackets, deepMinus, deepCalls }) {
            calculations[1] = new Map<String, Object>{ 'name' => 'Big', 'type' => 'formula', 'expression' => deep };
            DocBuilderDesignerController.CalcResult tooDeep = DocBuilderDesignerController.calcValues(
                JSON.serialize(new Map<String, Object>{ 'blocks' => new List<Object>(), 'calculations' => calculations }),
                'Opportunity',
                opp.Id
            );
            System.assertEquals(false, tooDeep.ok);
            System.assert(tooDeep.message.contains('nested too deeply'), tooDeep.message);
        }
        calculations[1] = new Map<String, Object>{ 'name' => 'Big', 'type' => 'formula', 'expression' => 'ROUND(' + '('.repeat(10) + '7.25' + ')'.repeat(10) + ', 1)' };
        DocBuilderDesignerController.CalcResult nested = DocBuilderDesignerController.calcValues(
            JSON.serialize(new Map<String, Object>{ 'blocks' => new List<Object>(), 'calculations' => calculations }),
            'Opportunity',
            opp.Id
        );
        System.assert(nested.ok, nested.message);
        System.assertEquals('7.3', nested.values.get('Big'));

        List<Boolean> results = new List<Boolean>{ true, false };
        System.assertEquals(true, new DocBuilderContext.LogicParser('NOT NOT (1 OR 2)', results).parse());
        for (String deepLogic : new List<String>{ '('.repeat(300) + '1' + ')'.repeat(300), 'NOT '.repeat(300) + '1' }) {
            try {
                new DocBuilderContext.LogicParser(deepLogic, results).parse();
                System.assert(false, 'Deeply nested rule logic should fail');
            } catch (DocBuilder.DocBuilderException e) {
                System.assert(e.getMessage().contains('Rule logic cannot be read'), e.getMessage());
            }
        }

        DocBuilderDesignerController.ObjectInfo info = DocBuilderDesignerController.describeObject('Opportunity');
        Boolean stageListed = false;
        for (DocBuilderDesignerController.FieldInfo f : info.fields) {
            if (f.name == 'StageName') {
                stageListed = f.values != null && !f.values.isEmpty();
            }
        }
        System.assert(stageListed, 'Picklist values are offered to rule editors');
    }

    @IsTest
    static void tableColumnsShowOnlyWhenFilledOrWhenTheirRuleIsMet() {
        Account acct = new Account(Name = 'Column Co');
        insert acct;
        insert new List<Contact>{
            new Contact(AccountId = acct.Id, LastName = 'Nair', Department = 'Operations'),
            new Contact(AccountId = acct.Id, LastName = 'Rivera')
        };
        Opportunity opp = new Opportunity(AccountId = acct.Id, Name = 'Deal C', StageName = 'Prospecting', CloseDate = Date.today(), Amount = 3000);
        insert opp;

        List<Object> columns = new List<Object>{
            new Map<String, Object>{ 'header' => 'Surname', 'field' => 'LastName' },
            new Map<String, Object>{ 'header' => 'DeptCol', 'field' => 'Department', 'show' => 'filled' },
            new Map<String, Object>{ 'header' => 'TitleCol', 'field' => 'Title', 'show' => 'filled' },
            new Map<String, Object>{
                'header' => 'MailCol',
                'field' => 'Email',
                'show' => 'rule',
                'showIf' => new Map<String, Object>{ 'conditions' => new List<Object>{ cond('Amount', 'gt', 5000) } }
            },
            new Map<String, Object>{
                'header' => 'PhoneCol',
                'field' => 'Phone',
                'show' => 'rule',
                'showIf' => new Map<String, Object>{ 'conditions' => new List<Object>{ cond('Amount', 'gt', 1000) } }
            }
        };
        List<Object> blocks = new List<Object>{
            new Map<String, Object>{
                'id' => 'people',
                'type' => 'table',
                'source' => 'Account.Contacts',
                'columns' => columns,
                'totals' => new List<Object>{ new Map<String, Object>{ 'label' => 'People', 'calc' => 'People' } }
            },
            new Map<String, Object>{
                'id' => 'empty',
                'type' => 'table',
                'source' => 'Account.Contacts',
                'columns' => new List<Object>{ new Map<String, Object>{ 'header' => 'OnlyTitleCol', 'field' => 'Title', 'show' => 'filled' } }
            }
        };
        List<Object> calculations = new List<Object>{ new Map<String, Object>{ 'name' => 'People', 'type' => 'count', 'source' => 'Account.Contacts' } };
        String body = JSON.serialize(new Map<String, Object>{ 'blocks' => blocks, 'calculations' => calculations });

        System.assertEquals(null, DocBuilderDesignerController.check(body, 'Opportunity'), 'Fields used by column rules are checked too');
        String html = DocBuilderEngine.previewHtml(body, 'Opportunity', opp.Id, null, null);
        System.assert(html.contains('Surname') && html.contains('DeptCol'), 'Always and filled columns print: ' + html);
        System.assert(!html.contains('TitleCol'), 'A column that is blank in every row is left out');
        System.assert(!html.contains('MailCol'), 'A column whose rule is not met is left out');
        System.assert(html.contains('PhoneCol'), 'A column whose rule is met prints');
        System.assert(html.contains('colspan="2"'), 'The total row spans only the printed columns: ' + html);
        System.assert(!html.contains('OnlyTitleCol'), 'A table whose every column is hidden is left out');
    }

    @IsTest
    static void earlierVersionsCanBePutLiveOrCopiedIntoTheDraft() {
        String v1Body = '{"blocks":[{"id":"a","type":"text","text":"ONE"}]}';
        String v2Body = '{"blocks":[{"id":"a","type":"text","text":"TWO"}]}';
        Id templateId = DocBuilderSamples.createTemplate('Versioned', 'Opportunity', null, v1Body);
        DocBuilderDesignerController.saveDraft(templateId, 'Versioned', null, null, v2Body);
        DocBuilderDesignerController.TemplateState state = DocBuilderDesignerController.activate(templateId);
        Id v2 = state.versionId;
        insert new DocTranslation__c(Template_Version__c = v2, Language__c = 'fr', Block_Id__c = 'a', Part__c = 'text', Source_Text__c = 'TWO', Translated_Text__c = 'DEUX');

        List<DocBuilderDesignerController.VersionInfo> versions = DocBuilderDesignerController.listVersions(templateId);
        System.assertEquals(2, versions.size());
        System.assertEquals(2, versions[0].versionNumber, 'Newest first');
        System.assertEquals('Active', versions[0].status);
        System.assertEquals('Archived', versions[1].status);
        Id v1 = versions[1].id;

        // Put version 1 back live.
        state = DocBuilderDesignerController.makeVersionLive(templateId, v1);
        System.assertEquals(v1, [SELECT Active_Version__c FROM DocTemplate__c WHERE Id = :templateId].Active_Version__c);
        System.assertEquals('Archived', [SELECT Status__c FROM DocTemplateVersion__c WHERE Id = :v2].Status__c);
        System.assertEquals(1, state.activeVersionNumber);

        // Copy version 2 into a new draft, translations included, without touching what is live.
        state = DocBuilderDesignerController.copyVersionToDraft(templateId, v2);
        System.assertEquals('Draft', state.versionStatus);
        System.assertEquals(3, state.versionNumber);
        System.assert(state.bodyJson.contains('TWO'));
        List<DocTranslation__c> copied = [SELECT Translated_Text__c FROM DocTranslation__c WHERE Template_Version__c = :state.versionId];
        System.assertEquals(1, copied.size());
        System.assertEquals('DEUX', copied[0].Translated_Text__c);
        System.assertEquals(v1, [SELECT Active_Version__c FROM DocTemplate__c WHERE Id = :templateId].Active_Version__c);

        // Copying again replaces the draft's content instead of adding another draft.
        Id draftId = state.versionId;
        state = DocBuilderDesignerController.copyVersionToDraft(templateId, v1);
        System.assertEquals(draftId, state.versionId);
        System.assert(state.bodyJson.contains('ONE'));
        System.assertEquals(0, [SELECT COUNT() FROM DocTranslation__c WHERE Template_Version__c = :draftId]);

        // Refusals: the draft cannot be put live or copied this way, nor the live version put live again,
        // nor a version of another template.
        Id otherTemplate = DocBuilderSamples.createTemplate('Other', 'Opportunity', null, v1Body);
        Id otherVersion = [SELECT Active_Version__c FROM DocTemplate__c WHERE Id = :otherTemplate].Active_Version__c;
        Map<String, String> attempts = new Map<String, String>{ 'live-draft' => 'is the draft', 'live-live' => 'already live', 'copy-draft' => 'already the draft', 'live-other' => 'not part of this template' };
        for (String attempt : attempts.keySet()) {
            try {
                if (attempt == 'live-draft') {
                    DocBuilderDesignerController.makeVersionLive(templateId, draftId);
                } else if (attempt == 'live-live') {
                    DocBuilderDesignerController.makeVersionLive(templateId, v1);
                } else if (attempt == 'copy-draft') {
                    DocBuilderDesignerController.copyVersionToDraft(templateId, draftId);
                } else {
                    DocBuilderDesignerController.makeVersionLive(templateId, otherVersion);
                }
                System.assert(false, attempt + ' should be refused');
            } catch (AuraHandledException e) {
                System.assert(e.getMessage().contains(attempts.get(attempt)), attempt + ': ' + e.getMessage());
            }
        }

        // A version that no longer passes the field check is not put live.
        update new DocTemplateVersion__c(Id = v2, Body_JSON__c = '{"blocks":[{"id":"a","type":"text","text":"{{No_Such_Field__c}}"}]}');
        try {
            DocBuilderDesignerController.makeVersionLive(templateId, v2);
            System.assert(false, 'A broken version should not go live');
        } catch (AuraHandledException e) {
            System.assert(e.getMessage().contains('cannot be put live'), e.getMessage());
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
        // A4 landscape with narrow margins, header and footer leaves a 273 x 162 mm content area. 12 letters fit at
        // 82pt, and the 34.7 mm line is centred 63.6 mm from the top of the content area.
        System.assert(html.contains('position:fixed;left:0;top:63.6mm;width:273.0mm;text-align:center;font-size:82pt;'), html);
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

    static Map<String, Object> textBlock(String id, String text, Map<String, Object> extra) {
        Map<String, Object> blk = new Map<String, Object>{ 'id' => id, 'type' => 'text', 'text' => text };
        if (extra != null) {
            blk.putAll(extra);
        }
        return blk;
    }

    static Map<String, Object> contactTable(String id, String department, String direction, String totalCalc) {
        return new Map<String, Object>{
            'id' => id,
            'type' => 'table',
            'source' => 'Account.Contacts',
            'orderBy' => 'LastName',
            'orderDirection' => direction,
            'columns' => new List<Object>{ new Map<String, Object>{ 'header' => 'Name', 'field' => 'LastName' } },
            'rowFilter' => new Map<String, Object>{ 'conditions' => new List<Object>{ cond('Department', 'eq', department) } },
            'totals' => new List<Object>{ new Map<String, Object>{ 'label' => department + ' people', 'calc' => totalCalc } }
        };
    }

    @IsTest
    static void conditionsInTextColumnsAndTablesSharingAList() {
        Account acct = new Account(Name = 'Harbor Sample Co', Industry = 'Logistics');
        insert acct;
        insert new List<Contact>{
            new Contact(AccountId = acct.Id, LastName = 'Nair', Department = 'Operations'),
            new Contact(AccountId = acct.Id, LastName = 'Tanaka', Department = 'Operations'),
            new Contact(AccountId = acct.Id, LastName = 'Rivera', Department = 'Technology'),
            new Contact(AccountId = acct.Id, LastName = 'Abbott', Department = 'Technology')
        };
        Opportunity opp = new Opportunity(AccountId = acct.Id, Name = 'Deal B', StageName = 'Prospecting', CloseDate = Date.today(), Amount = 3000);
        insert opp;

        Map<String, Object> body = new Map<String, Object>{
            'conditions' => new List<Object>{
                new Map<String, Object>{ 'name' => 'NotLogistics', 'rule' => new Map<String, Object>{ 'conditions' => new List<Object>{ cond('Account.Industry', 'ne', 'Logistics') } } }
            },
            'calculations' => new List<Object>{
                new Map<String, Object>{ 'name' => 'OpsCount', 'type' => 'count', 'source' => 'Account.Contacts', 'filter' => new Map<String, Object>{ 'conditions' => new List<Object>{ cond('Department', 'eq', 'Operations') } } },
                new Map<String, Object>{ 'name' => 'TechCount', 'type' => 'count', 'source' => 'Account.Contacts', 'filter' => new Map<String, Object>{ 'conditions' => new List<Object>{ cond('Department', 'eq', 'Technology') } } }
            },
            'blocks' => new List<Object>{
                textBlock('a', 'City: {{#if Account.BillingCity}}{{Account.BillingCity}}, {{/if}}Done {{#if cond:NotLogistics}}NOT-LOG{{else}}IS-LOG{{/if}} {{#if not Account.Phone}}NO-PHONE{{/if}}', null),
                textBlock('b', '{{#if Name}}A{{#if Account.Phone}}B{{else}}C{{/if}}D{{/if}}', null),
                textBlock('left', 'LEFT-CELL', new Map<String, Object>{ 'span' => 50 }),
                textBlock('right', 'RIGHT-CELL', new Map<String, Object>{ 'span' => 50, 'beside' => true }),
                textBlock('third', 'THIRD-CELL', new Map<String, Object>{ 'span' => 33 }),
                textBlock('rich', '<p>{{#if Account.Phone}}<b>PHONE</b>{{else}}<i>NO-PHONE-RICH</i>{{/if}}</p>', new Map<String, Object>{ 'rich' => true }),
                contactTable('ops', 'Operations', 'DESC', 'OpsCount'),
                contactTable('tech', 'Technology', 'ASC', 'TechCount')
            }
        };
        Id templateId = DocBuilderSamples.createTemplate('Layout', 'Opportunity', null, JSON.serialize(body));
        DocBuilder.Request req = new DocBuilder.Request();
        req.templateId = templateId;
        req.recordId = opp.Id;
        DocBuilder.Result res = DocBuilder.generate(req);
        System.assert(res.success, res.errorMessage);
        String html = fileText(res.contentVersionId);

        System.assert(html.contains('City: Done IS-LOG NO-PHONE'), html);
        System.assert(html.contains('>ACD<'), 'Nested sections with an else');
        System.assert(html.contains('<i>NO-PHONE-RICH</i>') && !html.contains('PHONE</b>'), 'Sections work in rich text');
        System.assert(html.contains('<td class="col" style="width:50%"><p>LEFT-CELL</p></td><td class="col" style="width:50%"><p>RIGHT-CELL</p></td>'), html);
        System.assert(html.contains('<td class="col" style="width:33%"><p>THIRD-CELL</p></td><td class="col" style="width:67%"></td>'), 'A narrow block on its own keeps its width');

        Integer tanaka = html.indexOf('Tanaka');
        Integer nair = html.indexOf('Nair');
        Integer abbott = html.indexOf('Abbott');
        Integer rivera = html.indexOf('Rivera');
        System.assert(tanaka < nair, 'First table: Operations only, descending');
        System.assert(nair < abbott && abbott < rivera, 'Second table: Technology only, ascending, after the first');
        System.assertEquals(1, html.countMatches('Tanaka'), 'Each person appears only in their own table');
        System.assert(html.contains('Operations people 2</td>') && html.contains('Technology people 2</td>'), 'Each table has its own filtered total');

        Map<String, Object> snapshot = (Map<String, Object>) JSON.deserializeUntyped([SELECT Snapshot_JSON__c FROM GeneratedDocument__c WHERE Id = :res.documentId].Snapshot_JSON__c);
        System.assert(((Map<String, Object>) snapshot.get('logic')).containsKey('cond:NotLogistics'), 'Named conditions are kept in the audit snapshot');
        System.assert(((Map<String, Object>) snapshot.get('values')).containsKey('Account.BillingCity'), 'Fields tested in text are kept in the audit snapshot');

        // Mistakes in sections fail with a plain explanation.
        Map<String, String> broken = new Map<String, String>{
            '{{#if Name}}open' => 'without a matching {{/if}}',
            'close{{/if}}' => 'without a matching {{#if}}',
            'x{{else}}y' => 'outside an {{#if}}',
            '{{#if cond:Missing}}x{{/if}}' => 'not defined'
        };
        for (String text : broken.keySet()) {
            Id badId = DocBuilderSamples.createTemplate('Bad ' + text.length(), 'Opportunity', null, JSON.serialize(new Map<String, Object>{ 'blocks' => new List<Object>{ textBlock('x', text, null) } }));
            req.templateId = badId;
            DocBuilder.Result failed = DocBuilder.generate(req);
            System.assertEquals(false, failed.success, text);
            System.assert(failed.errorMessage.contains(broken.get(text)), failed.errorMessage);
        }
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
