@IsTest
private class DocBuilderImportTest {
    @TestSetup
    static void grantPermissions() {
        DocBuilderTestUtil.grantAdmin();
    }

    @IsTest
    static void namesAreSimplifiedTheSameWayForApiNamesAndLabels() {
        System.assertEquals('quote', DocBuilderImport.simplify('SBQQ__Quote__c'));
        System.assertEquals('discount', DocBuilderImport.simplify('Discount__c'));
        System.assertEquals('account', DocBuilderImport.simplify('SBQQ__Account__r'));
        System.assertEquals('closedate', DocBuilderImport.simplify('Close Date'));
        System.assertEquals('', DocBuilderImport.simplify(null));
        System.assertEquals('Amount', DocBuilderImport.cleanToken(' Amount \\* MERGEFORMAT '));
        System.assertEquals('Amount', DocBuilderImport.cleanToken('Amount|currency'));
        System.assertEquals('quote.Name', DocBuilderImport.cleanToken('!quote.Name'));
    }

    @IsTest
    static void mergeFieldsInTheUsualStylesAreMatched() {
        List<String> tokens = new List<String>{
            'Opportunity.Name', // dotted, with the object as root
            'Account.Name', // a parent field
            'OPPORTUNITY_ACCOUNT_NAME', // Conga style
            'ACCOUNT_BILLINGCITY',
            'Close Date', // a label
            'Amount \\* MERGEFORMAT', // a Word field with switches
            '!opportunity.StageName', // Salesforce merge syntax
            'Account.Owner.Name', // two levels up
            'No_Such_Thing'
        };
        Map<String, String> found = DocBuilderDesignerController.suggestFields('Opportunity', tokens, null);
        System.assertEquals('Name', found.get('Opportunity.Name'));
        System.assertEquals('Account.Name', found.get('Account.Name'));
        System.assertEquals('Account.Name', found.get('OPPORTUNITY_ACCOUNT_NAME'));
        System.assertEquals('Account.BillingCity', found.get('ACCOUNT_BILLINGCITY'));
        System.assertEquals('CloseDate', found.get('Close Date'));
        System.assertEquals('Amount', found.get('Amount \\* MERGEFORMAT'));
        System.assertEquals('StageName', found.get('!opportunity.StageName'));
        System.assertEquals('Account.Owner.Name', found.get('Account.Owner.Name'));
        System.assert(!found.containsKey('No_Such_Thing'), 'Nothing is guessed when nothing fits');

        // Fields of a repeating row, written with the list name, a shortened list name, a generic root or Conga style.
        Map<String, String> rows = DocBuilderDesignerController.suggestFields(
            'OpportunityLineItem',
            new List<String>{ 'OpportunityLineItems.Quantity', 'LineItems.UnitPrice', 'line.TotalPrice', 'PRODUCT2_NAME' },
            'OpportunityLineItems'
        );
        System.assertEquals('Quantity', rows.get('OpportunityLineItems.Quantity'));
        System.assertEquals('UnitPrice', rows.get('LineItems.UnitPrice'));
        System.assertEquals('TotalPrice', rows.get('line.TotalPrice'));
        System.assertEquals('Product2.Name', rows.get('PRODUCT2_NAME'));

        System.assertEquals(0, DocBuilderDesignerController.suggestFields('Not_An_Object__x', new List<String>{ 'Name' }, null).size());
        System.assertEquals(0, DocBuilderDesignerController.suggestFields('Opportunity', null, null).size());
    }

    @IsTest
    static void cpqTemplatesBecomeHtmlWithALineItemTableAndTerms() {
        Map<String, Object> template = new Map<String, Object>{ 'Name' => 'Standard Proposal', 'SBQQ__CompanyName__c' => 'Acme & Co', 'SBQQ__CompanyCity__c' => 'Pune' };
        List<Map<String, Object>> sections = new List<Map<String, Object>>{
            new Map<String, Object>{ 'name' => 'Intro', 'type' => 'HTML', 'markup' => '<p>From {!template.SBQQ__CompanyName__c} to {!quote.SBQQ__Account__r.Name}</p>' },
            new Map<String, Object>{ 'name' => 'Lines', 'type' => 'Line Items', 'pageBreak' => true },
            new Map<String, Object>{ 'name' => 'Terms', 'type' => 'Quote Terms' },
            new Map<String, Object>{ 'name' => 'Chart', 'type' => 'Custom' }
        };
        List<Map<String, Object>> columns = new List<Map<String, Object>>{
            new Map<String, Object>{ 'heading' => 'Product', 'field' => 'SBQQ__ProductName__c' },
            new Map<String, Object>{ 'heading' => 'Qty', 'field' => 'SBQQ__Quantity__c' }
        };
        List<Map<String, Object>> terms = new List<Map<String, Object>>{ new Map<String, Object>{ 'body' => 'Pay {!template.SBQQ__CompanyName__c} in 30 days' } };

        DocBuilderImportSources.Loaded loaded = DocBuilderImportSources.cpqTemplate(template, sections, columns, terms);
        System.assertEquals('html', loaded.kind);
        System.assertEquals('SBQQ__Quote__c', loaded.baseObject);
        System.assert(loaded.content.contains('From Acme &amp; Co to {!quote.SBQQ__Account__r.Name}'), 'Template values are filled in, quote fields are kept: ' + loaded.content);
        System.assert(loaded.content.contains('<div style="page-break-before:always"><table><tr><th>Product</th><th>Qty</th></tr>'), loaded.content);
        System.assert(loaded.content.contains('<td>{{#each SBQQ__LineItems__r}}{!line.SBQQ__ProductName__c}</td><td>{!line.SBQQ__Quantity__c}{{/each}}</td>'), loaded.content);
        System.assert(loaded.content.contains('<h3>Terms</h3><ol><li>Pay Acme &amp; Co in 30 days</li></ol>'), loaded.content);
        System.assertEquals('Acme & Co · Pune', loaded.header);
        System.assert(String.join(loaded.notes, ' ').contains('Visualforce page'), loaded.notes);

        DocBuilderImportSources.Loaded bare = DocBuilderImportSources.cpqTemplate(new Map<String, Object>(), new List<Map<String, Object>>(), columns, terms);
        System.assert(bare.content.contains('{{#each SBQQ__LineItems__r}}') && String.join(bare.notes, ' ').contains('standard layout'), bare);
        DocBuilderImportSources.Loaded noColumns = DocBuilderImportSources.cpqTemplate(template, new List<Map<String, Object>>{ sections[1] }, new List<Map<String, Object>>(), terms);
        System.assert(String.join(noColumns.notes, ' ').contains('no line columns'), noColumns.notes);
    }

    @IsTest
    static void templatesInInstalledToolsAreListedAndTheirFilesRead() {
        // None of the tools is installed where tests run, so "Conga" is pointed at Account records here.
        System.assertEquals(0, DocBuilderDesignerController.listImportSources().size(), 'Nothing is offered when no tool is installed');
        DocBuilderImportSources.testObjects.put('conga', 'Account');
        Account withWord = new Account(Name = 'Quote Letter');
        Account withHtml = new Account(Name = 'Old Attachment');
        Account empty = new Account(Name = 'No File');
        insert new List<Account>{ withWord, withHtml, empty };
        insert new ContentVersion(Title = 'letter', PathOnClient = 'letter.docx', VersionData = Blob.valueOf('PK-fake-docx'), FirstPublishLocationId = withWord.Id);
        insert new Attachment(ParentId = withHtml.Id, Name = 'body.html', Body = Blob.valueOf('<p>Hi {{Name}}</p>'));

        List<DocBuilderImportSources.Candidate> found = DocBuilderDesignerController.listImportSources();
        System.assertEquals(3, found.size());
        System.assertEquals('Conga Composer', found[0].sourceLabel);

        DocBuilderImportSources.Loaded word = DocBuilderDesignerController.loadImportSource('conga', withWord.Id);
        System.assertEquals('docx', word.kind);
        System.assertEquals('PK-fake-docx', EncodingUtil.base64Decode(word.content).toString());
        DocBuilderImportSources.Loaded html = DocBuilderDesignerController.loadImportSource('conga', withHtml.Id);
        System.assertEquals('html', html.kind);
        System.assertEquals('<p>Hi {{Name}}</p>', html.content);

        Map<String, List<Object>> refusals = new Map<String, List<Object>>{
            'No Word (.docx) or HTML file' => new List<Object>{ 'conga', empty.Id },
            'could not be found' => new List<Object>{ 'nope', empty.Id },
            'could not be found ' => new List<Object>{ 'cpq', empty.Id }
        };
        for (String expected : refusals.keySet()) {
            try {
                DocBuilderDesignerController.loadImportSource((String) refusals.get(expected)[0], (Id) refusals.get(expected)[1]);
                System.assert(false, expected + ' should be refused');
            } catch (AuraHandledException e) {
                System.assert(e.getMessage().contains(expected.trim()), expected + ': ' + e.getMessage());
            }
        }
    }

    @IsTest
    static void theStandardQuoteLayoutIsCreatedAndUsesRealFields() {
        DocBuilderDesignerController.TemplateState state = DocBuilderDesignerController.createStandardQuoteTemplate('');
        System.assertEquals('Draft', state.versionStatus);
        System.assertEquals('Quote', state.baseObject);
        System.assertEquals(null, DocBuilderDesignerController.check(state.bodyJson, 'Quote'), 'Every field it uses exists on Quote');
        System.assert(state.bodyJson.contains('QuoteLineItems') && state.bodyJson.contains('GrandTotal'));
        System.assertEquals('Standard Quote', [SELECT Name FROM DocTemplate__c WHERE Id = :state.templateId].Name);
    }

    @IsTest
    static void anImportIsCreatedAsADraftAndBadInputIsRefused() {
        String body = '{"blocks":[{"id":"a","type":"heading","level":1,"text":"Quote {{Name}}"},{"id":"b","type":"table","source":"OpportunityLineItems","columns":[{"header":"Qty","field":"Quantity"}]}],"page":{"footer":{"text":"","pageNumbers":true}}}';
        DocBuilderDesignerController.TemplateState state = DocBuilderDesignerController.importTemplate('Imported quote', 'opportunity', 'Quote {{Name}}', body);
        System.assertEquals('Draft', state.versionStatus);
        System.assertEquals('Opportunity', state.baseObject, 'The object name is taken from Salesforce');
        System.assertEquals(1, state.versionNumber);
        System.assertEquals(null, [SELECT Active_Version__c FROM DocTemplate__c WHERE Id = :state.templateId].Active_Version__c, 'Nothing is live until activated');
        System.assertEquals(null, DocBuilderDesignerController.check(state.bodyJson, 'Opportunity'));

        Map<String, List<String>> refusals = new Map<String, List<String>>{
            'required' => new List<String>{ '', 'Opportunity', body },
            'not a DocBuilder template' => new List<String>{ 'X', 'Opportunity', '{"foo":1}' },
            'not an object' => new List<String>{ 'X', 'Nope__x', body },
            'empty or too large' => new List<String>{ 'X', 'Opportunity', '' }
        };
        for (String expected : refusals.keySet()) {
            List<String> args = refusals.get(expected);
            try {
                DocBuilderDesignerController.importTemplate(args[0], args[1], null, args[2]);
                System.assert(false, expected + ' should be refused');
            } catch (AuraHandledException e) {
                System.assert(e.getMessage().contains(expected), expected + ': ' + e.getMessage());
            }
        }
    }
}
