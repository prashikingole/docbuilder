/**
 * Content from code for a "Custom content" block set to "Apex class". Use it for anything a template cannot
 * express on its own: a complex table, a chart drawn as an image, or data from outside Salesforce.
 *
 *   global with sharing class AcmeWarrantyTable implements DocBuilderContentProvider {
 *       global String render(DocBuilderContentRequest request) {
 *           List<Asset> assets = [SELECT Name, UsageEndDate FROM Asset
 *                                 WHERE AccountId IN (SELECT AccountId FROM Opportunity WHERE Id = :request.recordId)
 *                                 WITH USER_MODE];
 *           String html = '<table class="t"><tr><th>Asset</th><th>Warranty ends</th></tr>';
 *           for (Asset a : assets) {
 *               html += '<tr><td>' + a.Name.escapeHtml4() + '</td><td>' + a.UsageEndDate + '</td></tr>';
 *           }
 *           return html + '</table>';
 *       }
 *   }
 *
 * Rules for implementations:
 *  - Return HTML for Salesforce's PDF engine: simple tables, paragraphs and inline styles (CSS 2.1, no flexbox).
 *  - Escape every data value (escapeHtml4). Scripts, frames, forms and event attributes are removed anyway.
 *  - Read data with the running user's access (with sharing, WITH USER_MODE): the class runs for whoever generates.
 *  - Keep it fast; it runs once per document, including in bulk generation.
 */
global interface DocBuilderContentProvider {
    String render(DocBuilderContentRequest request);
}
