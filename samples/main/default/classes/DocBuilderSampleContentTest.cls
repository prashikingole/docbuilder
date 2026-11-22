@IsTest
private class DocBuilderSampleContentTest {
    static Opportunity makeData() {
        Account acct = new Account(Name = 'Sample Co', Industry = 'Energy');
        insert acct;
        Opportunity opp = new Opportunity(AccountId = acct.Id, Name = 'Sample Deal', StageName = 'Prospecting', CloseDate = Date.today(), Pricebook2Id = Test.getStandardPricebookId());
        insert opp;
        insert new Opportunity(AccountId = acct.Id, Name = 'Won Before', StageName = 'Closed Won', CloseDate = Date.today().addDays(-30), Amount = 1000);
        List<Product2> products = new List<Product2>{
            new Product2(Name = 'Generator <XL>', Family = 'Hardware', IsActive = true),
            new Product2(Name = 'Install', Family = 'Services', IsActive = true),
            new Product2(Name = 'Cable', IsActive = true)
        };
        insert products;
        List<PricebookEntry> entries = new List<PricebookEntry>();
        for (Product2 p : products) {
            entries.add(new PricebookEntry(Pricebook2Id = Test.getStandardPricebookId(), Product2Id = p.Id, UnitPrice = 100, IsActive = true));
        }
        insert entries;
        List<OpportunityLineItem> lines = new List<OpportunityLineItem>();
        for (PricebookEntry e : entries) {
            lines.add(new OpportunityLineItem(OpportunityId = opp.Id, PricebookEntryId = e.Id, Quantity = 2, UnitPrice = 100));
        }
        insert lines;
        return opp;
    }

    @IsTest
    static void productSummaryGroupsByFamily() {
        Opportunity opp = makeData();
        DocBuilderContentRequest request = new DocBuilderContentRequest();
        request.recordId = opp.Id;
        request.settings = '{"title":"Your investment"}';
        String html = new DocBuilderSampleProductSummary().render(request);
        System.assert(html.contains('Your investment') && html.contains('Hardware subtotal') && html.contains('Services subtotal') && html.contains('Other subtotal'), html);
        System.assert(html.contains('Generator &lt;XL&gt;'), 'Names are escaped');
        System.assert(html.contains('Total</td><td class="r">' + UserInfo.getDefaultCurrency() + ' 600.00'), 'Grand total of 3 lines x 2 x 100: ' + html);
        System.assert(html.indexOf('Hardware subtotal') < html.indexOf('Services subtotal') && html.indexOf('Services subtotal') < html.indexOf('Other subtotal'), 'Families in order, Other last');

        request.settings = 'Plain title';
        System.assert(new DocBuilderSampleProductSummary().render(request).contains('Plain title'));
        request.recordId = null;
        System.assert(new DocBuilderSampleProductSummary().render(request).contains('real record'));
        request.recordId = opp.AccountId;
        System.assert(new DocBuilderSampleProductSummary().render(request).contains('quotes and opportunities'));
        System.assertEquals(null, DocBuilderRenderer.checkContentProvider('DocBuilderSampleProductSummary'));
    }

    @IsTest
    static void openCasesCheckLooksAtTheAccount() {
        Opportunity opp = makeData();
        DocBuilderContentRequest request = new DocBuilderContentRequest();
        request.recordId = opp.Id;
        DocBuilderSampleOpenCasesCheck check = new DocBuilderSampleOpenCasesCheck();
        System.assertEquals(false, check.evaluate(request));
        insert new Case(AccountId = opp.AccountId, Subject = 'Broken', Priority = 'Medium', Status = 'New');
        System.assertEquals(true, check.evaluate(request));
        request.settings = '{"priority":"High"}';
        System.assertEquals(false, check.evaluate(request), 'Only high-priority cases count with that setting');
        request.settings = null;
        request.recordId = opp.AccountId;
        System.assertEquals(true, check.evaluate(request), 'Works on the account itself');
        request.recordId = UserInfo.getUserId();
        System.assertEquals(false, check.evaluate(request), 'Records without an account answer no');
        request.recordId = null;
        System.assertEquals(false, check.evaluate(request));
    }

    @IsTest
    static void accountVariablesOfferManyValuesFromOneClass() {
        Opportunity opp = makeData();
        insert new Case(AccountId = opp.AccountId, Subject = 'Urgent', Priority = 'High', Status = 'New');
        DocBuilderSampleAccountVariables facts = new DocBuilderSampleAccountVariables();
        System.assertEquals(7, facts.describeVariables().size());
        DocBuilderContentRequest request = new DocBuilderContentRequest();
        request.recordId = opp.Id;
        Map<String, Object> values = facts.getValues(request);
        System.assertEquals(true, values.get('HasOpenCases'));
        System.assertEquals(1, values.get('OpenCaseCount'));
        System.assertEquals(true, values.get('HasHighPriorityCases'));
        System.assertEquals(1, values.get('WonDealCount'));
        System.assertEquals(1000, (Decimal) values.get('WonAmount'));
        System.assertEquals(Date.today().addDays(-30), values.get('LastWonDate'));
        System.assertEquals('Bronze', values.get('CustomerTier'));
        request.settings = '{"goldFrom": 900, "silverFrom": 500}';
        System.assertEquals('Gold', facts.getValues(request).get('CustomerTier'));
        request.recordId = UserInfo.getUserId();
        System.assert(facts.getValues(request).isEmpty(), 'Records without an account have no values');
        System.assertEquals(7, DocBuilderContext.variablesOf('DocBuilderSampleAccountVariables').size());
    }

    @IsTest
    static void accountCardShowsTheAccountAndWins() {
        Opportunity opp = makeData();
        Test.setCurrentPage(Page.DocBuilderSampleAccountCard);
        ApexPages.currentPage().getParameters().put('id', opp.Id);
        DocBuilderSampleAccountCardController card = new DocBuilderSampleAccountCardController();
        System.assert(card.getHasAccount());
        System.assertEquals('Sample Co', card.account.Name);
        System.assert(card.getHasWins());
        System.assertEquals('Won Before', card.wins[0].Name);

        ApexPages.currentPage().getParameters().put('id', 'not-an-id');
        System.assert(!new DocBuilderSampleAccountCardController().getHasAccount());
        ApexPages.currentPage().getParameters().put('id', opp.AccountId);
        System.assert(new DocBuilderSampleAccountCardController().getHasAccount());
        ApexPages.currentPage().getParameters().put('id', UserInfo.getUserId());
        System.assert(!new DocBuilderSampleAccountCardController().getHasWins());
    }
}
