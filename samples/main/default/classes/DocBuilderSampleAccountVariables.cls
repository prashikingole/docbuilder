/**
 * SAMPLE Apex variables: one class, many values about the account behind the record (a quote, opportunity,
 * contact, case or the account itself). Add a variable in the designer for each value you need; no new class.
 *
 *   HasOpenCases (Boolean)   OpenCaseCount (Number)   HasHighPriorityCases (Boolean)
 *   WonDealCount (Number)    WonAmount (Number)       LastWonDate (Date)        CustomerTier (Text)
 *
 * Settings (optional) change the tier thresholds: {"goldFrom": 500000, "silverFrom": 100000}
 * Examples in a template: {{apex:CustomerTier}} customer since {{apex:LastWonDate}};
 * a rule "Apex: WonAmount is greater than 250000"; {{#if apex:HasOpenCases}}...{{/if}}.
 */
global with sharing class DocBuilderSampleAccountVariables implements DocBuilderVariableProvider {
    global Map<String, String> describeVariables() {
        return new Map<String, String>{
            'HasOpenCases' => 'Boolean',
            'OpenCaseCount' => 'Number',
            'HasHighPriorityCases' => 'Boolean',
            'WonDealCount' => 'Number',
            'WonAmount' => 'Number',
            'LastWonDate' => 'Date',
            'CustomerTier' => 'Text'
        };
    }

    global Map<String, Object> getValues(DocBuilderContentRequest request) {
        Map<String, Object> values = new Map<String, Object>();
        Id accountId = accountOf(request.recordId);
        if (accountId == null) {
            return values;
        }
        Integer openCases = [SELECT COUNT() FROM Case WHERE AccountId = :accountId AND IsClosed = FALSE WITH USER_MODE];
        Integer highPriority = [SELECT COUNT() FROM Case WHERE AccountId = :accountId AND IsClosed = FALSE AND Priority = 'High' WITH USER_MODE];
        AggregateResult won = [SELECT COUNT(Id) deals, SUM(Amount) amount, MAX(CloseDate) lastWon FROM Opportunity WHERE AccountId = :accountId AND IsWon = TRUE WITH USER_MODE];
        Decimal wonAmount = won.get('amount') == null ? 0 : (Decimal) won.get('amount');

        Decimal goldFrom = 500000;
        Decimal silverFrom = 100000;
        if (String.isNotBlank(request.settings)) {
            Map<String, Object> settings = (Map<String, Object>) JSON.deserializeUntyped(request.settings);
            goldFrom = settings.get('goldFrom') == null ? goldFrom : Decimal.valueOf(String.valueOf(settings.get('goldFrom')));
            silverFrom = settings.get('silverFrom') == null ? silverFrom : Decimal.valueOf(String.valueOf(settings.get('silverFrom')));
        }

        values.put('HasOpenCases', openCases > 0);
        values.put('OpenCaseCount', openCases);
        values.put('HasHighPriorityCases', highPriority > 0);
        values.put('WonDealCount', (Integer) won.get('deals'));
        values.put('WonAmount', wonAmount);
        values.put('LastWonDate', (Date) won.get('lastWon'));
        values.put('CustomerTier', wonAmount >= goldFrom ? 'Gold' : (wonAmount >= silverFrom ? 'Silver' : 'Bronze'));
        return values;
    }

    /** The account a record belongs to: itself for an account, otherwise its AccountId field. */
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
        // The object name comes from the record Id's own type, never from user input.
        List<SObject> rows = Database.queryWithBinds('SELECT AccountId FROM ' + d.getName() + ' WHERE Id = :recordId', new Map<String, Object>{ 'recordId' => recordId }, AccessLevel.USER_MODE);
        return rows.isEmpty() ? null : (Id) rows[0].get('AccountId');
    }
}
