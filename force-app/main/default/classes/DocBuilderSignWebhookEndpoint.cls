/**
 * Public address that signature providers call when a request changes:
 *   https://<your site>/services/apexrest/docbuilder/sign/<ProviderName>?token=<secret>
 *
 * Security design:
 *  - The secret is kept in the Signature Webhook Secret custom setting, not in metadata users can query,
 *    and is compared through HMAC digests so the comparison time reveals nothing about it.
 *  - Every rejection (unknown provider, wrong or missing secret, provider without notification support)
 *    gets the same 401 and an empty body.
 *  - Nothing in the notification is trusted. The endpoint only raises a Signature Notice event naming the
 *    request; the handler then asks the provider for the real status. The guest user never reads or
 *    writes DocBuilder records and never calls the provider.
 */
@RestResource(urlMapping='/docbuilder/sign/*')
global with sharing class DocBuilderSignWebhookEndpoint {
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
        response.statusCode = 401;

        String providerName;
        DocBuilderSignWebhook hook;
        try {
            providerName = request.requestURI == null ? null : request.requestURI.substringAfterLast('/');
            if (!authorised(providerName, request.params.get('token'))) {
                return;
            }
            DocBuilderSignProvider provider = DocBuilderSign.providerFor(providerName);
            if (!(provider instanceof DocBuilderSignWebhook)) {
                return;
            }
            hook = (DocBuilderSignWebhook) provider;
        } catch (Exception e) {
            // Details are never returned to an anonymous caller; they are kept for tests only.
            lastError = e.getMessage();
            return;
        }

        try {
            String externalId = hook.externalIdOf(request);
            if (String.isNotBlank(externalId)) {
                EventBus.publish(new DocSignNotice__e(Provider__c = providerName.left(80), External_Id__c = externalId.left(255)));
            }
            response.statusCode = 200;
            hook.respond(request, response);
        } catch (Exception e) {
            response.statusCode = 400;
            lastError = e.getMessage();
        }
    }

    @TestVisible
    static Boolean authorised(String providerName, String given) {
        if (String.isBlank(providerName) || String.isBlank(given) || providerName.length() > 38) {
            return false;
        }
        DocSignSecret__c row = DocSignSecret__c.getValues(providerName);
        String expected = row == null ? null : row.Webhook_Secret__c;
        if (String.isBlank(expected)) {
            return false;
        }
        // Comparing keyed digests instead of the raw strings keeps the comparison time independent of the secret.
        Blob key = Crypto.generateAesKey(256);
        String a = EncodingUtil.convertToHex(Crypto.generateMac('hmacSHA256', Blob.valueOf(expected), key));
        String b = EncodingUtil.convertToHex(Crypto.generateMac('hmacSHA256', Blob.valueOf(given), key));
        return a.equals(b);
    }
}
