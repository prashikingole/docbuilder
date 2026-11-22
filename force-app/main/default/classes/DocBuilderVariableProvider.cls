/**
 * Any number of values from one Apex class, for use in templates as Apex variables. Write the class once;
 * admins then add a variable in the designer (Conditions > Apex variables) for each value they need, and use
 * it in any rule as apex:Name, in text as {{apex:Name}}, or as {{#if apex:Name}} ... {{/if}}.
 * Adding a value later only means adding it to the two maps below: no new class, no template change elsewhere.
 *
 *   global with sharing class AccountFacts implements DocBuilderVariableProvider {
 *       global Map<String, String> describeVariables() {
 *           return new Map<String, String>{ 'OpenCaseCount' => 'Number', 'HasOpenCases' => 'Boolean', 'Tier' => 'Text' };
 *       }
 *       global Map<String, Object> getValues(DocBuilderContentRequest request) {
 *           Integer open = ...; // queries WITH USER_MODE for request.recordId
 *           return new Map<String, Object>{ 'OpenCaseCount' => open, 'HasOpenCases' => open > 0, 'Tier' => 'Gold' };
 *       }
 *   }
 *
 * describeVariables: each value's name and type (Boolean, Number, Text or Date), so the designer can list them and
 * offer the right comparisons. getValues: every value for one record; it runs once per class (and Settings text)
 * per document, however many variables use it, as the user generating the document. request.recordId is null
 * when the designer only checks the template.
 */
global interface DocBuilderVariableProvider {
    Map<String, String> describeVariables();
    Map<String, Object> getValues(DocBuilderContentRequest request);
}
