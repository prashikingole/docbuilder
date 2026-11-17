@IsTest
private class DocBuilderTest {
    @TestSetup
    static void grantPermissions() {
        DocBuilderTestUtil.grantAdmin();
    }

    static Map<String, Object> cond(String field, String op, Object value) {
        return new Map<String, Object>{ 'field' => field, 'op' => op, 'value' => value };
    }

    static Map<String, Object> rule(String logic, List<Object> conditions) {
        return new Map<String, Object>{ 'logic' => logic, 'conditions' => conditions };
    }

    static String accountBody(String ruleLogic) {
        List<Object> blocks = new List<Object>{
            new Map<String, Object>{ 'id' => 'h', 'type' => 'heading', 'level' => 2, 'text' => 'Summary for {{Name|upper}}' },
            new Map<String, Object>{
                'type' => 'text',
                'align' => 'right',
                'text' => 'Revenue {{AnnualRevenue}} staff {{NumberOfEmployees}} owner {{Owner.Name}}\nPipeline {{calc:Pipeline}} avg {{calc:AvgDeal}} low {{calc:Smallest}} high {{calc:Largest|number}}'
            },
            new Map<String, Object>{
                'id' => 'shown',
                'type' => 'text',
                'text' => 'RULE-SHOWN',
                'showIf' => rule(ruleLogic, new List<Object>{ cond('Industry', 'eq', 'Logistics'), cond('AnnualRevenue', 'gt', 10000), cond('calc:People', 'gt', 99) })
            },
            new Map<String, Object>{
                'id' => 'hidden',
                'type' => 'text',
                'text' => 'RULE-HIDDEN',
                'elseText' => 'ELSE-SHOWN for {{Name}}',
                'showIf' => rule('OR', new List<Object>{ cond('Industry', 'eq', 'Retail'), cond('Industry', 'contains', 'zzz'), cond('Fax', 'notBlank', null) })
            },
            new Map<String, Object>{
                'id' => 'people',
                'type' => 'table',
                'source' => 'Contacts',
                'orderBy' => 'LastName',
                'orderDirection' => 'DESC',
                'columns' => new List<Object>{
                    new Map<String, Object>{ 'header' => 'Last name', 'field' => 'LastName' },
                    new Map<String, Object>{ 'field' => 'Department', 'align' => 'center', 'format' => 'upper' },
                    new Map<String, Object>{ 'header' => 'Born', 'field' => 'Birthdate', 'align' => 'right' }
                },
                'rowFilter' => rule(null, new List<Object>{ cond('Department', 'eq', 'Operations') }),
                'totals' => new List<Object>{ new Map<String, Object>{ 'label' => 'Operations people', 'calc' => 'OpsPeople' } }
            },
            new Map<String, Object>{ 'type' => 'table', 'source' => 'Cases', 'hideWhenEmpty' => true, 'columns' => new List<Object>{ new Map<String, Object>{ 'field' => 'Subject' } } },
            new Map<String, Object>{
                'id' => 'terms',
                'type' => 'terms',
                'title' => 'Terms for {{Name}}',
                'items' => new List<Object>{
                    new Map<String, Object>{ 'text' => 'CLAUSE-ALWAYS' },
                    new Map<String, Object>{ 'id' => 'never', 'text' => 'CLAUSE-NEVER', 'showIf' => rule('AND', new List<Object>{ cond('Industry', 'ne', 'Logistics') }) },
                    new Map<String, Object>{ 'text' => 'CLAUSE-NUMERIC', 'showIf' => rule('1 AND 2 AND 3 AND NOT 4', new List<Object>{ cond('AnnualRevenue', 'ge', 12000), cond('AnnualRevenue', 'le', 12000), cond('NumberOfEmployees', 'lt', 41), cond('AnnualRevenue', 'ne', 12000) }) }
                }
            },
            new Map<String, Object>{ 'type' => 'pagebreak' }
        };
        List<Object> calculations = new List<Object>{
            new Map<String, Object>{ 'name' => 'People', 'type' => 'count', 'source' => 'Contacts' },
            new Map<String, Object>{ 'name' => 'OpsPeople', 'type' => 'count', 'source' => 'Contacts', 'filter' => rule(null, new List<Object>{ cond('Department', 'eq', 'Operations') }) },
            new Map<String, Object>{ 'name' => 'Pipeline', 'type' => 'sum', 'source' => 'Opportunities', 'field' => 'Amount', 'format' => 'currency' },
            new Map<String, Object>{ 'name' => 'AvgDeal', 'type' => 'avg', 'source' => 'Opportunities', 'field' => 'Amount' },
            new Map<String, Object>{ 'name' => 'Smallest', 'type' => 'min', 'source' => 'Opportunities', 'field' => 'Amount' },
            new Map<String, Object>{ 'name' => 'Largest', 'type' => 'max', 'source' => 'Opportunities', 'field' => 'Amount' }
        };
        return JSON.serialize(new Map<String, Object>{ 'blocks' => blocks, 'calculations' => calculations });
    }

    static Account makeAccount() {
        Account acct = new Account(Name = 'Harbor Sample Co', Industry = 'Logistics', AnnualRevenue = 12000, NumberOfEmployees = 40);
        insert acct;
        insert new List<Contact>{
            new Contact(AccountId = acct.Id, LastName = 'Nair', Department = 'Operations', Birthdate = Date.newInstance(1990, 5, 17)),
            new Contact(AccountId = acct.Id, LastName = 'Rivera', Department = 'Technology'),
            new Contact(AccountId = acct.Id, LastName = 'Tanaka', Department = 'Operations')
        };
        insert new List<Opportunity>{
            new Opportunity(AccountId = acct.Id, Name = 'Deal A', StageName = 'Prospecting', CloseDate = Date.today().addDays(30), Amount = 1000),
            new Opportunity(AccountId = acct.Id, Name = 'Deal B', StageName = 'Prospecting', CloseDate = Date.today().addDays(30), Amount = 3000)
        };
        return acct;
    }

    static String fileText(Id contentVersionId) {
        return [SELECT VersionData FROM ContentVersion WHERE Id = :contentVersionId].VersionData.toString();
    }

    @IsTest
    static void generatesDocumentWithRulesTablesAndSnapshot() {
        Account acct = makeAccount();
        DocBuilderSamples.createTemplate('Account Summary', 'Account', 'Summary: {{Name}} / {{Industry}}', accountBody('1 AND (2 OR 3)'));

        DocBuilder.Request req = new DocBuilder.Request();
        req.templateName = 'Account Summary';
        req.recordId = acct.Id;
        req.emailTo = new List<String>{ 'someone@example.com' };

        Test.startTest();
        DocBuilder.Result res = DocBuilder.generate(req);
        Test.stopTest();

        System.assertEquals(null, res.errorMessage);
        System.assert(res.success);
        System.assertEquals('Summary Harbor Sample Co Logistics.pdf', res.fileName);

        String html = fileText(res.contentVersionId);
        System.assert(html.contains('Summary for HARBOR SAMPLE CO'), html);
        System.assert(html.contains('RULE-SHOWN'));
        System.assert(!html.contains('RULE-HIDDEN'));
        System.assert(html.contains('ELSE-SHOWN for Harbor Sample Co'));
        System.assert(html.contains('Nair') && html.contains('Tanaka'));
        System.assert(!html.contains('Rivera'), 'Row filter should drop the Technology contact');
        System.assert(html.indexOf('Tanaka') < html.indexOf('Nair'), 'Rows should be sorted descending');
        System.assert(html.contains('OPERATIONS'));
        System.assert(html.contains('CLAUSE-ALWAYS') && html.contains('CLAUSE-NUMERIC'));
        System.assert(!html.contains('CLAUSE-NEVER'));
        System.assert(html.contains('4,000.00'), 'Sum of opportunity amounts should be formatted as currency');
        System.assert(html.contains('page-break-after'));

        GeneratedDocument__c doc = [
            SELECT Status__c, Channel__c, Record_Id__c, Object__c, Snapshot_JSON__c, Email_Status__c, Template_Version__c
            FROM GeneratedDocument__c
            WHERE Id = :res.documentId
        ];
        System.assertEquals('Success', doc.Status__c);
        System.assertEquals('Apex', doc.Channel__c);
        System.assertEquals('Account', doc.Object__c);
        System.assertNotEquals(null, doc.Template_Version__c);
        System.assertNotEquals(null, doc.Email_Status__c);

        Map<String, Object> snapshot = (Map<String, Object>) JSON.deserializeUntyped(doc.Snapshot_JSON__c);
        Map<String, Object> values = (Map<String, Object>) snapshot.get('values');
        System.assertEquals('Logistics', values.get('Industry'), 'Rule-driving fields must be in the snapshot even when not printed');
        Map<String, Object> logic = (Map<String, Object>) snapshot.get('logic');
        System.assertEquals(true, ((Map<String, Object>) logic.get('shown')).get('result'));
        System.assertEquals(false, ((Map<String, Object>) logic.get('hidden')).get('result'));
        System.assertEquals(3, ((List<Object>) ((Map<String, Object>) snapshot.get('lists')).get('Contacts')).size());
        System.assertEquals(1, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :acct.Id]);
    }

    @IsTest
    static void failuresAreReturnedAndLogged() {
        Account acct = makeAccount();

        DocBuilder.Request missing = new DocBuilder.Request();
        missing.templateName = 'Does Not Exist';
        missing.recordId = acct.Id;
        DocBuilder.Result res = DocBuilder.generate(missing);
        System.assertEquals(false, res.success);
        System.assert(res.errorMessage.contains('No template found'));

        Id badLogic = DocBuilderSamples.createTemplate('Bad Logic', 'Account', null, accountBody('1 AND ('));
        DocBuilder.Request bad = new DocBuilder.Request();
        bad.templateId = badLogic;
        bad.recordId = acct.Id;
        res = DocBuilder.generate(new List<DocBuilder.Request>{ bad })[0];
        System.assertEquals(false, res.success);
        System.assert(res.errorMessage.contains('Rule logic cannot be read'), res.errorMessage);
        System.assertEquals('Failed', [SELECT Status__c FROM GeneratedDocument__c WHERE Id = :res.documentId].Status__c);

        Contact person = [SELECT Id FROM Contact LIMIT 1];
        DocBuilder.Request wrongObject = new DocBuilder.Request();
        wrongObject.templateId = badLogic;
        wrongObject.recordId = person.Id;
        res = DocBuilder.generate(wrongObject);
        System.assert(res.errorMessage.contains('is built on Account'));

        Id badField = DocBuilderSamples.createTemplate('Bad Field', 'Account', null, '{"blocks":[{"type":"text","text":"{{Name; DROP}}"}]}');
        DocBuilder.Request injected = new DocBuilder.Request();
        injected.templateId = badField;
        injected.recordId = acct.Id;
        System.assert(DocBuilder.generate(injected).errorMessage.contains('not a valid field'));

        Id badCalc = DocBuilderSamples.createTemplate('Bad Calc', 'Account', null, '{"blocks":[{"type":"text","text":"{{calc:Nope}}"}]}');
        DocBuilder.Request missingCalc = new DocBuilder.Request();
        missingCalc.templateId = badCalc;
        missingCalc.recordId = acct.Id;
        System.assert(DocBuilder.generate(missingCalc).errorMessage.contains('is not defined'));

        update new DocTemplate__c(Id = badCalc, Status__c = 'Inactive');
        System.assert(DocBuilder.generate(missingCalc).errorMessage.contains('not active'));
        System.assert(DocBuilder.generate(new DocBuilder.Request()).errorMessage.contains('record ID is required'));
    }

    @IsTest
    static void flowActionAndButtonControllerWork() {
        Account acct = makeAccount();
        Id templateId = DocBuilderSamples.createTemplate('Account Summary', 'Account', null, accountBody('OR'));

        DocBuilderFlowAction.Input input = new DocBuilderFlowAction.Input();
        input.templateName = 'Account Summary';
        input.recordId = acct.Id;
        input.emailTo = 'a@example.com; b@example.com';
        input.saveToRecord = false;
        DocBuilderFlowAction.Output output = DocBuilderFlowAction.generate(new List<DocBuilderFlowAction.Input>{ input })[0];
        System.assertEquals(null, output.errorMessage);
        System.assert(output.success);
        System.assertEquals('Account Summary.pdf', output.fileName);
        System.assertEquals('Flow', [SELECT Channel__c FROM GeneratedDocument__c WHERE Id = :output.documentId].Channel__c);
        System.assertEquals(0, [SELECT COUNT() FROM ContentDocumentLink WHERE LinkedEntityId = :acct.Id]);

        // The button reads templates as the user, so the user needs the packaged permission set.
        User me = new User(Id = UserInfo.getUserId());
        PermissionSet adminSet = [SELECT Id FROM PermissionSet WHERE Name = 'DocBuilder_Admin'];
        if ([SELECT COUNT() FROM PermissionSetAssignment WHERE AssigneeId = :me.Id AND PermissionSetId = :adminSet.Id] == 0) {
            System.runAs(me) {
                insert new PermissionSetAssignment(AssigneeId = me.Id, PermissionSetId = adminSet.Id);
            }
        }
        DocBuilder.Result res;
        System.runAs(me) {
            List<DocTemplate__c> available = DocBuilderController.getTemplates(acct.Id);
            System.assertEquals(1, available.size());
            res = DocBuilderController.generate(new List<Id>{ templateId }, acct.Id, null, false, 'a@example.com b@example.com', 'Subject', 'Body');
            System.assert(DocBuilderController.preview(templateId, acct.Id, null).contains('Harbor'));
        }
        System.assert(res.success, res.errorMessage);
        System.assertEquals('Button', [SELECT Channel__c FROM GeneratedDocument__c WHERE Id = :res.documentId].Channel__c);
    }

    @IsTest
    static void sampleQuoteGeneratesForAnOpportunity() {
        Account acct = makeAccount();
        Opportunity opp = [SELECT Id FROM Opportunity WHERE Name = 'Deal B'];
        Id templateId = DocBuilderSamples.installOpportunityQuote();
        System.assertEquals(templateId, DocBuilderSamples.installOpportunityQuote(), 'Installing twice should reuse the template');

        DocBuilder.Request req = new DocBuilder.Request();
        req.templateName = DocBuilderSamples.QUOTE_NAME;
        req.recordId = opp.Id;
        DocBuilder.Result res = DocBuilder.generate(req);
        System.assert(res.success, res.errorMessage);

        String html = fileText(res.contentVersionId);
        System.assert(html.contains('Harbor Sample Co'));
        System.assert(html.contains('Standard onboarding applies'), 'Amount is below the threshold so the fallback text prints');
        System.assert(!html.contains('<table'), 'The products table hides itself when there are no line items');
    }

    @IsTest
    static void logicParserHandlesPrecedenceAndErrors() {
        List<Boolean> r = new List<Boolean>{ true, false, false };
        System.assertEquals(true, new DocBuilderContext.LogicParser('1 OR 2 AND 3', r).parse());
        System.assertEquals(false, new DocBuilderContext.LogicParser('(1 OR 2) AND 3', r).parse());
        System.assertEquals(true, new DocBuilderContext.LogicParser('not 2 and (1 or 3)', r).parse());
        for (String broken : new List<String>{ '1 AND', '4', '1 XOR 2', '(1 OR 2', '', '1 2' }) {
            try {
                new DocBuilderContext.LogicParser(broken, r).parse();
                System.assert(false, 'Expected "' + broken + '" to be rejected');
            } catch (DocBuilder.DocBuilderException e) {
                System.assert(e.getMessage().contains('cannot be read'));
            }
        }
    }
}
