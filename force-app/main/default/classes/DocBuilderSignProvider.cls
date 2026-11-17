/**
 * The contract every e-signature provider implements.
 *
 * To connect a provider that is not built in:
 *   1. Write a global class that implements this interface.
 *   2. Add a Signature Provider row (Setup > Custom Metadata Types) naming your class,
 *      its Named Credential and the button label. Tick Active.
 * Nothing else in DocBuilder needs to change: the designer, the Generate dialog, the Flow action
 * and the Apex API all work through this interface.
 */
global interface DocBuilderSignProvider {
    /**
     * The hidden marker DocBuilder prints in the PDF where a signer's field belongs, in whatever
     * form the provider recognises (an anchor string, a text tag, and so on).
     * signerNumber starts at 1. fieldType is one of: signature, date, name, initials.
     * Return an empty string if the provider places fields another way.
     */
    String marker(Integer signerNumber, String fieldType);

    /** Sends the document for signature and returns the provider's own reference for it. */
    DocBuilderSign.SendResult send(DocBuilderSign.Envelope envelope);

    /** Reports where the request stands. Statuses: Sent, Completed, Declined, Voided. */
    DocBuilderSign.StatusResult getStatus(DocBuilderSign.ProviderConfig config, String externalId);

    /** Returns the signed PDF. May return null, in which case the sent copy is kept as the record. */
    Blob download(DocBuilderSign.ProviderConfig config, String externalId);

    /** Withdraws a request that has not been completed. */
    void cancel(DocBuilderSign.ProviderConfig config, String externalId, String reason);
}
