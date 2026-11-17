/**
 * HTTP helpers shared by the built-in providers. Custom providers are welcome to use them too.
 */
global with sharing class DocBuilderSignHttp {
    /**
     * A provider refused a call. The message is safe to show users; the provider's own response, which can
     * contain internal detail, is kept in `detail` and stored only in the admin-only Error Detail field.
     */
    global class ProviderException extends Exception {
        global String detail;
    }

    static final Pattern ID_PATTERN = Pattern.compile('^[A-Za-z0-9._*:-]{1,255}$');

    /**
     * Makes a provider reference (envelope, agreement or request ID) safe to put in a URL path.
     * Rejects anything that is not a plain identifier, so a stored value cannot steer a call to another endpoint.
     */
    global static String pathId(String reference) {
        if (reference == null || !ID_PATTERN.matcher(reference).matches()) {
            throw new DocBuilder.DocBuilderException('The provider reference is not a valid identifier.');
        }
        return EncodingUtil.urlEncode(reference, 'UTF-8');
    }

    /** A message fit for any user: DocBuilder's own messages as they are, anything else replaced with a plain one. */
    global static String userMessage(Exception e) {
        if (e instanceof DocBuilder.DocBuilderException || e instanceof ProviderException) {
            return e.getMessage();
        }
        return 'Something went wrong. An administrator can see the details on this record.';
    }

    /** Technical detail for administrators. */
    global static String detailOf(Exception e) {
        String detail = e.getTypeName() + ': ' + e.getMessage();
        if (e instanceof ProviderException && ((ProviderException) e).detail != null) {
            detail += '\n' + ((ProviderException) e).detail;
        }
        return detail + '\n' + e.getStackTraceString();
    }

    /** Calls the provider through its Named Credential and fails on any non-2xx status. */
    global static HttpResponse call(DocBuilderSign.ProviderConfig config, String method, String path, String contentType, Blob body) {
        if (String.isBlank(config.namedCredential)) {
            throw new DocBuilder.DocBuilderException('Signature provider "' + config.name + '" has no Named Credential set.');
        }
        HttpRequest request = new HttpRequest();
        request.setEndpoint('callout:' + config.namedCredential + path);
        request.setMethod(method);
        request.setTimeout(120000);
        if (contentType != null) {
            request.setHeader('Content-Type', contentType);
        }
        if (body != null) {
            request.setBodyAsBlob(body);
        }
        HttpResponse response = new Http().send(request);
        if (response.getStatusCode() < 200 || response.getStatusCode() >= 300) {
            ProviderException failure = new ProviderException(config.label + ' refused the request (HTTP ' + response.getStatusCode() + ').');
            String responseBody = response.getBody();
            failure.detail = responseBody == null ? null : responseBody.left(2000);
            throw failure;
        }
        return response;
    }

    global static HttpResponse callJson(DocBuilderSign.ProviderConfig config, String method, String path, Object payload) {
        return call(config, method, path, 'application/json', payload == null ? null : Blob.valueOf(JSON.serialize(payload)));
    }

    global static Map<String, Object> parse(HttpResponse response) {
        return (Map<String, Object>) JSON.deserializeUntyped(response.getBody());
    }

    global static String boundary() {
        return 'DocBuilder' + EncodingUtil.convertToHex(Crypto.generateAesKey(128)).left(24);
    }

    /**
     * Builds a multipart/form-data body holding text fields and one PDF.
     * The parts are joined as hex because Apex cannot otherwise join text and binary data.
     */
    global static Blob multipart(String boundary, Map<String, String> fields, String fileField, String fileName, Blob file) {
        String head = '';
        for (String key : fields.keySet()) {
            head += '--' + boundary + '\r\nContent-Disposition: form-data; name="' + key + '"\r\n\r\n' + fields.get(key) + '\r\n';
        }
        head += '--' + boundary + '\r\nContent-Disposition: form-data; name="' + fileField + '"; filename="' + fileName.replace('"', '') + '"\r\nContent-Type: application/pdf\r\n\r\n';
        String tail = '\r\n--' + boundary + '--\r\n';
        return EncodingUtil.convertFromHex(EncodingUtil.convertToHex(Blob.valueOf(head)) + EncodingUtil.convertToHex(file) + EncodingUtil.convertToHex(Blob.valueOf(tail)));
    }

    global static List<Object> listOf(Object value) {
        return value == null ? new List<Object>() : (List<Object>) value;
    }

    global static Datetime parseTime(Object value) {
        if (value == null || String.isBlank(String.valueOf(value))) {
            return null;
        }
        try {
            return (Datetime) JSON.deserialize('"' + String.valueOf(value) + '"', Datetime.class);
        } catch (Exception e) {
            return null;
        }
    }
}
