/**
 * DocuSign eSignature REST API v2.1.
 * Named Credential: URL = the account's base URI (for example https://demo.docusign.net), with OAuth sign-in.
 * Settings JSON: { "accountId": "<API account ID>" }
 * Fields are placed with anchor strings printed in the document.
 */
global with sharing class DocBuilderSignDocuSign implements DocBuilderSignProvider, DocBuilderSignWebhook {
    static final Map<String, String> CODES = new Map<String, String>{ 'signature' => 'sig', 'date' => 'date', 'name' => 'name', 'initials' => 'init' };

    global String marker(Integer signerNumber, String fieldType) {
        return '/ds' + (CODES.containsKey(fieldType) ? CODES.get(fieldType) : 'sig') + signerNumber + '/';
    }

    String base(DocBuilderSign.ProviderConfig config) {
        Object accountId = config.settings.get('accountId');
        if (accountId == null || String.isBlank(String.valueOf(accountId))) {
            throw new DocBuilder.DocBuilderException('Add your DocuSign account ID to the provider Settings JSON as {"accountId":"..."}.');
        }
        return '/restapi/v2.1/accounts/' + String.valueOf(accountId).trim();
    }

    Map<String, Object> anchor(Integer signerNumber, String fieldType) {
        return new Map<String, Object>{
            'anchorString' => marker(signerNumber, fieldType),
            'anchorUnits' => 'pixels',
            'anchorXOffset' => '0',
            'anchorYOffset' => '0',
            // A template may not print every field for every signer.
            'anchorIgnoreIfNotPresent' => 'true'
        };
    }

    global DocBuilderSign.SendResult send(DocBuilderSign.Envelope envelope) {
        List<Object> signers = new List<Object>();
        Integer n = 0;
        for (DocBuilderSign.Signer signer : envelope.signers) {
            n++;
            signers.add(
                new Map<String, Object>{
                    'email' => signer.email,
                    'name' => signer.name,
                    'recipientId' => String.valueOf(n),
                    'routingOrder' => String.valueOf(signer.routingOrder == null ? n : signer.routingOrder),
                    'tabs' => new Map<String, Object>{
                        'signHereTabs' => new List<Object>{ anchor(n, 'signature') },
                        'dateSignedTabs' => new List<Object>{ anchor(n, 'date') },
                        'fullNameTabs' => new List<Object>{ anchor(n, 'name') },
                        'initialHereTabs' => new List<Object>{ anchor(n, 'initials') }
                    }
                }
            );
        }
        Map<String, Object> payload = new Map<String, Object>{
            'emailSubject' => envelope.subject == null ? 'Please sign' : envelope.subject.left(100),
            'emailBlurb' => envelope.message,
            'status' => 'sent',
            'documents' => new List<Object>{
                new Map<String, Object>{ 'documentBase64' => EncodingUtil.base64Encode(envelope.file), 'name' => envelope.fileName, 'fileExtension' => 'pdf', 'documentId' => '1' }
            },
            'recipients' => new Map<String, Object>{ 'signers' => signers }
        };
        Map<String, Object> answer = DocBuilderSignHttp.parse(DocBuilderSignHttp.callJson(envelope.config, 'POST', base(envelope.config) + '/envelopes', payload));
        DocBuilderSign.SendResult result = new DocBuilderSign.SendResult();
        result.externalId = (String) answer.get('envelopeId');
        return result;
    }

    global DocBuilderSign.StatusResult getStatus(DocBuilderSign.ProviderConfig config, String externalId) {
        Map<String, Object> answer = DocBuilderSignHttp.parse(DocBuilderSignHttp.call(config, 'GET', base(config) + '/envelopes/' + externalId + '?include=recipients', null, null));
        DocBuilderSign.StatusResult result = new DocBuilderSign.StatusResult();
        String status = String.valueOf(answer.get('status')).toLowerCase();
        result.status = status == 'completed' ? 'Completed' : (status == 'declined' ? 'Declined' : (status == 'voided' ? 'Voided' : 'Sent'));
        Object recipients = answer.get('recipients');
        if (recipients instanceof Map<String, Object>) {
            for (Object s : DocBuilderSignHttp.listOf(((Map<String, Object>) recipients).get('signers'))) {
                Map<String, Object> signer = (Map<String, Object>) s;
                DocBuilderSign.SignerStatus row = new DocBuilderSign.SignerStatus();
                row.email = (String) signer.get('email');
                String signerStatus = String.valueOf(signer.get('status')).toLowerCase();
                row.status = signerStatus == 'completed' || signerStatus == 'signed' ? 'Signed' : (signerStatus == 'declined' ? 'Declined' : 'Sent');
                row.signedOn = DocBuilderSignHttp.parseTime(signer.get('signedDateTime'));
                result.signers.add(row);
            }
        }
        return result;
    }

    global Blob download(DocBuilderSign.ProviderConfig config, String externalId) {
        return DocBuilderSignHttp.call(config, 'GET', base(config) + '/envelopes/' + externalId + '/documents/combined', null, null).getBodyAsBlob();
    }

    global void cancel(DocBuilderSign.ProviderConfig config, String externalId, String reason) {
        DocBuilderSignHttp.callJson(config, 'PUT', base(config) + '/envelopes/' + externalId, new Map<String, Object>{ 'status' => 'voided', 'voidedReason' => reason });
    }

    // ---------- Instant updates (DocuSign Connect, JSON format) ----------

    global String externalIdOf(RestRequest request) {
        if (request.requestBody == null || request.requestBody.size() == 0) {
            return null;
        }
        Map<String, Object> event = (Map<String, Object>) JSON.deserializeUntyped(request.requestBody.toString());
        Object data = event.get('data');
        if (data instanceof Map<String, Object> && ((Map<String, Object>) data).get('envelopeId') != null) {
            return String.valueOf(((Map<String, Object>) data).get('envelopeId'));
        }
        return event.get('envelopeId') == null ? null : String.valueOf(event.get('envelopeId'));
    }

    global void respond(RestRequest request, RestResponse response) {
        response.responseBody = Blob.valueOf('OK');
    }
}
