/**
 * SAMPLE controller for the DocBuilderSampleAccountCard Visualforce page: a snapshot of the account behind the
 * record the document is generated for (?id=<record Id>), with its five most recent won opportunities.
 */
public with sharing class DocBuilderSampleAccountCardController {
    public Account account { get; private set; }
    public List<Opportunity> wins { get; private set; }

    public DocBuilderSampleAccountCardController() {
        wins = new List<Opportunity>();
        String raw = ApexPages.currentPage().getParameters().get('id');
        Id recordId;
        try {
            recordId = String.isBlank(raw) ? null : Id.valueOf(raw);
        } catch (Exception e) {
            recordId = null;
        }
        Id accountId = accountOf(recordId);
        if (accountId == null) {
            return;
        }
        List<Account> found = [
            SELECT Name, Industry, Type, BillingCity, BillingCountry, AnnualRevenue, NumberOfEmployees, Owner.Name
            FROM Account
            WHERE Id = :accountId
            WITH USER_MODE
        ];
        account = found.isEmpty() ? null : found[0];
        wins = [
            SELECT Name, CloseDate, Amount
            FROM Opportunity
            WHERE AccountId = :accountId AND IsWon = TRUE
            WITH USER_MODE
            ORDER BY CloseDate DESC
            LIMIT 5
        ];
    }

    public Boolean getHasAccount() {
        return account != null;
    }

    public Boolean getHasWins() {
        return !wins.isEmpty();
    }

    static Id accountOf(Id recordId) {
        if (recordId == null) {
            return null;
        }
        Schema.DescribeSObjectResult d = recordId.getSObjectType().getDescribe();
        if (d.getName() == 'Account') {
            return recordId;
        }
        if (!d.fields.getMap().containsKey('accountid')) {
            return null;
        }
        List<SObject> rows = Database.queryWithBinds('SELECT AccountId FROM ' + d.getName() + ' WHERE Id = :recordId', new Map<String, Object>{ 'recordId' => recordId }, AccessLevel.USER_MODE);
        return rows.isEmpty() ? null : (Id) rows[0].get('AccountId');
    }
}
