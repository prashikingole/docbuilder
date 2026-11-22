/**
 * A yes/no answer from code, registered in a template as an Apex check (Conditions panel) and used in any rule
 * as apex:Name, or in text as {{#if apex:Name}} ... {{/if}}. Use it for logic a rule cannot express: a credit
 * check, a lookup in another system, or a calculation over many records.
 *
 *   global with sharing class HasOpenHighPriorityCases implements DocBuilderConditionProvider {
 *       global Boolean evaluate(DocBuilderContentRequest request) {
 *           Id accountId = ...; // from request.recordId
 *           return [SELECT COUNT() FROM Case WHERE AccountId = :accountId AND IsClosed = false
 *                   AND Priority = 'High' WITH USER_MODE] > 0;
 *       }
 *   }
 *
 * The class runs as the user generating the document, at most once per check per document. request.settings
 * holds the text typed in the check's Settings box. Throwing an exception stops generation with its message.
 */
global interface DocBuilderConditionProvider {
    Boolean evaluate(DocBuilderContentRequest request);
}
