/**
 * Dropbox Sign (formerly HelloSign) API v3.
 * Named Credential: URL = https://api.hellosign.com, Basic authentication with the API key as the username and a blank password.
 * Settings JSON: { "testMode": true } sends test requests that are not legally binding and are not billed.
 * Fields are placed with text tags printed in the document.
 */
global with sharing class DocBuilderSignDropbox implements DocBuilderSignProvider, DocBuilderSignWebhook {
    global String marker(Integer signerNumber, String fieldType) {
        String who = 'signer' + signerNumber;
        if (fieldType == 'date') {
            return '[date|req|' + who + ']';
        }
        if (fieldType == 'name') {
            return '[text|req|' + who + '|Full name]';
        }
        if (fieldType == 'initials') {
            return '[initial|req|' + who + ']';
        }
        return '[sig|req|' + who + ']';
    }

    global DocBuilderSign.SendResult send(DocBuilderSign.Envelope envelope) {
        Map<String, String> fields = new Map<String, String>{
            'title' => envelope.fileName.removeEnd('.pdf'),
            'subject' => envelope.subject == null ? 'Please sign' : envelope.subject.left(255),
            'use_text_tags' => '1',
            'hide_text_tags' => '0'
        };
        if (String.isNotBlank(envelope.message)) {
            fields.put('message', envelope.message.left(5000));
        }
        if (envelope.config.settings.get('testMode') == true) {
            fields.put('test_mode', '1');
        }
        // Dropbox Sign sends to everyone at once unless an order is given, so the order is left out
        // when every signer shares the same position.
        Set<Integer> positions = new Set<Integer>();
        for (DocBuilderSign.Signer signer : envelope.signers) {
            positions.add(signer.routingOrder);
        }
        Boolean inOrder = positions.size() > 1 || positions.contains(null);
        Integer n = 0;
        for (DocBuilderSign.Signer signer : envelope.signers) {
            fields.put('signers[' + n + '][email_address]', signer.email);
            fields.put('signers[' + n + '][name]', String.isBlank(signer.name) ? signer.email : signer.name);
            if (inOrder) {
                fields.put('signers[' + n + '][order]', String.valueOf(signer.routingOrder == null ? n : signer.routingOrder - 1));
            }
            n++;
        }
        String boundary = DocBuilderSignHttp.boundary();
        Blob body = DocBuilderSignHttp.multipart(boundary, fields, 'files[0]', envelope.fileName, envelope.file);
        Map<String, Object> answer = DocBuilderSignHttp.parse(
            DocBuilderSignHttp.call(envelope.config, 'POST', '/v3/signature_request/send', 'multipart/form-data; boundary=' + boundary, body)
        );
        DocBuilderSign.SendResult result = new DocBuilderSign.SendResult();
        result.externalId = (String) ((Map<String, Object>) answer.get('signature_request')).get('signature_request_id');
        return result;
    }

    global DocBuilderSign.StatusResult getStatus(DocBuilderSign.ProviderConfig config, String externalId) {
        Map<String, Object> answer = DocBuilderSignHttp.parse(DocBuilderSignHttp.call(config, 'GET', '/v3/signature_request/' + externalId, null, null));
        Map<String, Object> request = (Map<String, Object>) answer.get('signature_request');
        DocBuilderSign.StatusResult result = new DocBuilderSign.StatusResult();
        if (request.get('is_complete') == true) {
            result.status = 'Completed';
        } else if (request.get('is_declined') == true) {
            result.status = 'Declined';
        } else {
            result.status = 'Sent';
        }
        for (Object s : DocBuilderSignHttp.listOf(request.get('signatures'))) {
            Map<String, Object> signature = (Map<String, Object>) s;
            DocBuilderSign.SignerStatus row = new DocBuilderSign.SignerStatus();
            row.email = (String) signature.get('signer_email_address');
            String code = String.valueOf(signature.get('status_code'));
            row.status = code == 'signed' ? 'Signed' : (code == 'declined' ? 'Declined' : 'Sent');
            if (signature.get('signed_at') != null) {
                // Dropbox Sign reports times as seconds since 1970.
                row.signedOn = Datetime.newInstance(Long.valueOf(String.valueOf(signature.get('signed_at'))) * 1000);
            }
            result.signers.add(row);
        }
        return result;
    }

    global Blob download(DocBuilderSign.ProviderConfig config, String externalId) {
        return DocBuilderSignHttp.call(config, 'GET', '/v3/signature_request/files/' + externalId + '?file_type=pdf', null, null).getBodyAsBlob();
    }

    global void cancel(DocBuilderSign.ProviderConfig config, String externalId, String reason) {
        DocBuilderSignHttp.call(config, 'POST', '/v3/signature_request/cancel/' + externalId, null, null);
    }

    // ---------- Instant updates (Dropbox Sign callbacks) ----------

    global String externalIdOf(RestRequest request) {
        // The event arrives as a form field named "json"; the ID is read straight out of the text.
        String text = request.params.get('json');
        if (String.isBlank(text) && request.requestBody != null) {
            text = request.requestBody.toString();
        }
        if (String.isBlank(text)) {
            return null;
        }
        Matcher m = Pattern.compile('"signature_request_id"\\s*:\\s*"([^"]+)"').matcher(text);
        return m.find() ? m.group(1) : null;
    }

    global void respond(RestRequest request, RestResponse response) {
        // Dropbox Sign keeps retrying unless it gets exactly this text back.
        response.responseBody = Blob.valueOf('Hello API Event Received');
    }
}
