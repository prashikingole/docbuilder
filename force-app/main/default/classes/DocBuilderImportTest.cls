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
