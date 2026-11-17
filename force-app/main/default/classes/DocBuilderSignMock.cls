/**
 * A provider that talks to nobody. It lets you try the whole signing flow, from the designer to the
 * signed copy on the record, before any real e-signature account is connected.
 * The request is reported as signed by everyone the first time its status is checked.
 * It is also the simplest example of a custom provider: copy it as a starting point.
 */
global with sharing class DocBuilderSignMock implements DocBuilderSignProvider {
    global String marker(Integer signerNumber, String fieldType) {
        // No hidden markers: the document shows plain signature lines.
        return '';
    }

    global DocBuilderSign.SendResult send(DocBuilderSign.Envelope envelope) {
        DocBuilderSign.SendResult result = new DocBuilderSign.SendResult();
        result.externalId = 'TEST-' + String.valueOf(System.now().getTime());
        return result;
    }

    global DocBuilderSign.StatusResult getStatus(DocBuilderSign.ProviderConfig config, String externalId) {
        DocBuilderSign.StatusResult result = new DocBuilderSign.StatusResult();
        result.status = 'Completed';
        return result;
    }

    global Blob download(DocBuilderSign.ProviderConfig config, String externalId) {
        // Returning null keeps the copy that was sent as the signed record.
        return null;
    }

    global void cancel(DocBuilderSign.ProviderConfig config, String externalId, String reason) {
        return;
    }
}
