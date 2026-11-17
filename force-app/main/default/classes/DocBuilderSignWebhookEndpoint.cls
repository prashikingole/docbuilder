/**
 * Public address that signature providers call when a request changes:
 *   https://<your site>/services/apexrest/docbuilder/sign/<ProviderName>?token=<secret>
 *
 * It never trusts what the notification says. It only uses it to learn WHICH request changed,
 * then asks the provider for the real status through the Named Credential.
 *
 * Runs without sharing on purpose: the caller is an anonymous site visitor with no record access,
 * and is let in only when the token matches the provider's "webhookSecret" setting.
 */
@RestResource(urlMapping='/docbuilder/sign/*')
global without sharing class DocBuilderSignWebhookEndpoint {
    @HttpPost
    global static void receive() {
        handle();
    }

    /** Some providers confirm the address with a GET before they start sending. */
    @HttpGet
    global static void verify() {
        handle();
    }

    @TestVisible
    static String lastError;

    static void handle() {
        RestRequest request = RestContext.request;
        RestResponse response = RestContext.response;
        try {
            String providerName = request.requestURI.substringAfterLast('/');
            DocBuilderSign.ProviderConfig config = DocBuilderSign.configFor(providerName);
            Object secret = config.settings.get('webhookSecret');
            String given = request.params.get('token');
            // equals() is case-sensitive; == is not.
            if (secret == null || String.isBlank(String.valueOf(secret)) || given == null || !String.valueOf(secret).equals(given)) {
                response.statusCode = 401;
                return;
            }
            DocBuilderSignProvider provider = DocBuilderSign.providerFor(providerName);
            if (!(provider instanceof DocBuilderSignWebhook)) {
                response.statusCode = 404;
                return;
            }
            DocBuilderSignWebhook hook = (DocBuilderSignWebhook) provider;
            String externalId = hook.externalIdOf(request);
            if (String.isNotBlank(externalId)) {
                List<DocSignRequest__c> found = [
                    SELECT Id
                    FROM DocSignRequest__c
                    WHERE Provider__c = :providerName AND External_Id__c = :externalId AND Status__c = 'Sent'
                    LIMIT 1
                ];
                if (!found.isEmpty()) {
                    System.enqueueJob(new DocBuilderSignSyncJob(new Set<Id>{ found[0].Id }));
                }
            }
            response.statusCode = 200;
            hook.respond(request, response);
        } catch (Exception e) {
            // Details are never returned to an anonymous caller; they are kept for tests only.
            response.statusCode = 400;
            lastError = e.getMessage() + ' ' + e.getStackTraceString();
        }
    }
}
