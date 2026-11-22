/**
 * SAMPLE Apex check: yes when the account behind the record (a quote, opportunity, contact, case or the account
 * itself) has open cases. Use it to print a support note, or to hide a renewal discount, only when it applies.
 *
 * Use it: Conditions > Apex checks > Add Apex check, name it e.g. OpenCases, class DocBuilderSampleOpenCasesCheck.
 * Settings (optional): {"priority": "High"} counts only cases with that priority.
 * Then in any rule pick "Apex check: OpenCases", or in text write {{#if apex:OpenCases}} ... {{/if}}.
 */
global with sharing class DocBuilderSampleOpenCasesCheck implements DocBuilderConditionProvider {
    global Boolean evaluate(DocBuilderContentRequest request) {
        Id accountId = accountOf(request.recordId);
        if (accountId == null) {
            return false;
        }
        String priority;
        if (String.isNotBlank(request.settings)) {
            Object value = ((Map<String, Object>) JSON.deserializeUntyped(request.settings)).get('priority');
            priority = value == null ? null : String.valueOf(value);
        }
        if (String.isBlank(priority)) {
            return [SELECT COUNT() FROM Case WHERE AccountId = :accountId AND IsClosed = FALSE WITH USER_MODE] > 0;
        }
        return [SELECT COUNT() FROM Case WHERE AccountId = :accountId AND IsClosed = FALSE AND Priority = :priority WITH USER_MODE] > 0;
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
