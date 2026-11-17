/**
 * Optional second interface for a signature provider that can push status changes to Salesforce
 * the moment they happen, instead of waiting for the scheduled check.
 * Implement it alongside DocBuilderSignProvider on the same class.
 */
global interface DocBuilderSignWebhook {
    /**
     * Reads the provider's notification and returns the reference of the request it is about
     * (the same value send() returned). Return null to ignore the notification.
     */
    String externalIdOf(RestRequest request);

    /** Writes whatever acknowledgement the provider expects. The status code is already 200. */
    void respond(RestRequest request, RestResponse response);
}
