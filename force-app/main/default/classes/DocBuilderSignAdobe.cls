/**
 * Adobe Acrobat Sign REST API v6.
 * Named Credential: URL = your account's API access point (for example https://api.na1.adobesign.com), with OAuth or an integration key.
 * Fields are placed with Acrobat Sign text tags printed in the document.
 */
global with sharing class DocBuilderSignAdobe implements DocBuilderSignProvider, DocBuilderSignWebhook {
    static final String API = '/api/rest/v6';

    global String marker(Integer signerNumber, String fieldType) {
        String who = ':signer' + signerNumber + ':';
        if (fieldType == 'date') {
            return '{{Dte_es_' + who + 'date}}';
        }
        if (fieldType == 'name') {
            return '{{Name_es_' + who + 'fullname}}';
        }
        if (fieldType == 'initials') {
            return '{{Int_es_' + who + 'initials}}';
        }
        return '{{Sig_es_' + who + 'signature}}';
    }

    global DocBuilderSign.SendResult send(DocBuilderSign.Envelope envelope) {
        // Step 1: upload the file. Acrobat Sign only accepts a document it has already received.
        String boundary = DocBuilderSignHttp.boundary();
        Blob upload = DocBuilderSignHttp.multipart(boundary, new Map<String, String>{ 'File-Name' => envelope.fileName, 'Mime-Type' => 'application/pdf' }, 'File', envelope.fileName, envelope.file);
        Map<String, Object> uploaded = DocBuilderSignHttp.parse(
            DocBuilderSignHttp.call(envelope.config, 'POST', API + '/transientDocuments', 'multipart/form-data; boundary=' + boundary, upload)
        );

        // Step 2: create the agreement from it.
        List<Object> participants = new List<Object>();
        Integer n = 0;
        for (DocBuilderSign.Signer signer : envelope.signers) {
            n++;
            participants.add(
                new Map<String, Object>{
                    'memberInfos' => new List<Object>{ new Map<String, Object>{ 'email' => signer.email } },
                    'order' => signer.routingOrder == null ? n : signer.routingOrder,
                    'role' => 'SIGNER'
                }
            );
        }
        Map<String, Object> payload = new Map<String, Object>{
            'fileInfos' => new List<Object>{ new Map<String, Object>{ 'transientDocumentId' => uploaded.get('transientDocumentId') } },
            'name' => envelope.subject == null ? envelope.fileName : envelope.subject.left(255),
            'message' => envelope.message,
            'participantSetsInfo' => participants,
            'signatureType' => 'ESIGN',
            'state' => 'IN_PROCESS'
        };
        Map<String, Object> answer = DocBuilderSignHttp.parse(DocBuilderSignHttp.callJson(envelope.config, 'POST', API + '/agreements', payload));
        DocBuilderSign.SendResult result = new DocBuilderSign.SendResult();
        result.externalId = (String) answer.get('id');
        return result;
    }

    global DocBuilderSign.StatusResult getStatus(DocBuilderSign.ProviderConfig config, String externalId) {
        Map<String, Object> agreement = DocBuilderSignHttp.parse(DocBuilderSignHttp.call(config, 'GET', API + '/agreements/' + externalId, null, null));
        DocBuilderSign.StatusResult result = new DocBuilderSign.StatusResult();
        String status = String.valueOf(agreement.get('status')).toUpperCase();
        if (status == 'SIGNED' || status == 'APPROVED' || status == 'COMPLETED') {
            result.status = 'Completed';
        } else if (status == 'CANCELLED' || status == 'EXPIRED') {
            result.status = 'Voided';
        } else {
            result.status = 'Sent';
        }

        Map<String, Object> members = DocBuilderSignHttp.parse(DocBuilderSignHttp.call(config, 'GET', API + '/agreements/' + externalId + '/members', null, null));
        for (Object ps : DocBuilderSignHttp.listOf(members.get('participantSets'))) {
            Map<String, Object> participantSet = (Map<String, Object>) ps;
            String setStatus = participantSet.get('status') == null ? '' : String.valueOf(participantSet.get('status')).toUpperCase();
            for (Object m : DocBuilderSignHttp.listOf(participantSet.get('memberInfos'))) {
                Map<String, Object> member = (Map<String, Object>) m;
                DocBuilderSign.SignerStatus row = new DocBuilderSign.SignerStatus();
                row.email = (String) member.get('email');
                String memberStatus = member.get('status') == null ? setStatus : String.valueOf(member.get('status')).toUpperCase();
                if (memberStatus == 'COMPLETED' || memberStatus == 'SIGNED') {
                    row.status = 'Signed';
                } else if (memberStatus == 'CANCELLED' || memberStatus == 'DECLINED') {
                    row.status = 'Declined';
                    result.status = result.status == 'Voided' ? 'Declined' : result.status;
                } else {
                    row.status = 'Sent';
                }
                result.signers.add(row);
            }
        }
        return result;
    }

    global Blob download(DocBuilderSign.ProviderConfig config, String externalId) {
        return DocBuilderSignHttp.call(config, 'GET', API + '/agreements/' + externalId + '/combinedDocument', null, null).getBodyAsBlob();
    }

    global void cancel(DocBuilderSign.ProviderConfig config, String externalId, String reason) {
        DocBuilderSignHttp.callJson(
            config,
            'PUT',
            API + '/agreements/' + externalId + '/state',
            new Map<String, Object>{ 'state' => 'CANCELLED', 'agreementCancellationInfo' => new Map<String, Object>{ 'comment' => reason, 'notifyOthers' => true } }
        );
    }

    // ---------- Instant updates (Acrobat Sign webhooks) ----------

    global String externalIdOf(RestRequest request) {
        if (request.requestBody == null || request.requestBody.size() == 0) {
            // The first call is a GET that only checks the address.
            return null;
        }
        Map<String, Object> event = (Map<String, Object>) JSON.deserializeUntyped(request.requestBody.toString());
        Object agreement = event.get('agreement');
        return agreement instanceof Map<String, Object> && ((Map<String, Object>) agreement).get('id') != null ? String.valueOf(((Map<String, Object>) agreement).get('id')) : null;
    }

    global void respond(RestRequest request, RestResponse response) {
        // Acrobat Sign requires its client ID to be echoed back, on the check and on every notification.
        String clientId = request.headers.get('X-AdobeSign-ClientId');
        if (clientId == null) {
            clientId = request.headers.get('x-adobesign-clientid');
        }
        if (clientId != null) {
            response.addHeader('X-AdobeSign-ClientId', clientId);
            response.addHeader('Content-Type', 'application/json');
            response.responseBody = Blob.valueOf(JSON.serialize(new Map<String, Object>{ 'xAdobeSignClientId' => clientId }));
        }
    }
}
