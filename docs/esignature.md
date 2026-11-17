# E-signature in DocBuilder

This guide is for the admin or developer setting up e-signature in an org that has DocBuilder installed. It covers switching on a built-in provider, connecting a provider that is not built in, and changing the buttons and screens users see.

## How it fits together

1. A template lists its **signers** and contains a **Signature block**.
2. When a user sends the document for signature, DocBuilder generates the PDF with the chosen provider's hidden field markers in the signature areas.
3. A **Signature Request** record is created and the document is sent to the provider in the background.
4. DocBuilder checks the provider for status. When everyone has signed, the signed copy is saved to Files on the source record.

Every provider, built-in or your own, is one row in **Setup › Custom Metadata Types › Signature Provider**.

| Field | What it is for |
|---|---|
| Label | The provider's name |
| Apex Class | The class that talks to the provider |
| Named Credential | Where the provider's address and sign-in are stored |
| Button Label | The text users see in the Generate dialog |
| Sort Order | The order providers are listed in |
| Settings JSON | Provider-specific settings |
| Custom Screen Flow | Optional. A screen flow that replaces the built-in signing form |
| Active | Only active providers are offered to users |

## Switch on a built-in provider

For each provider: create the Named Credential, fill in the settings, then tick **Active** on its row.

| Provider | Named Credential name | Named Credential URL | Sign-in | Settings JSON |
|---|---|---|---|---|
| DocuSign | `DocBuilder_DocuSign` | Your account's base address, e.g. `https://demo.docusign.net` | OAuth | `{"accountId":"<API account ID>"}` |
| Adobe Acrobat Sign | `DocBuilder_AdobeSign` | Your regional API address, e.g. `https://api.na1.adobesign.com` | OAuth or integration key | `{}` |
| Dropbox Sign | `DocBuilder_DropboxSign` | `https://api.hellosign.com` | Basic: API key as the username, blank password | `{"testMode":true}` while testing |

The **Test provider** row is active out of the box. It sends nothing and reports every signer as signed the first time status is checked, so you can try the whole flow before connecting a real account. Deactivate it before going live.

## Keep status up to date

There are two ways, and they can be used together.

**Scheduled check (recommended to start).** Run this once from the Developer Console's Anonymous Apex window:

```apex
DocBuilderSignSync.schedule();
```

Open requests are then checked every 15 minutes. `DocBuilderSignSync.unschedule();` stops it.

**Instant updates (optional).** The provider calls Salesforce the moment something changes.

1. Create a Salesforce Site and give its guest user access to the Apex class `DocBuilderSignWebhookEndpoint`. Give the guest user nothing else: it never reads DocBuilder records.
2. Choose a long random secret (at least 32 characters). In **Setup › Custom Settings › Signature Webhook Secret › Manage**, add a row whose **Name** is the provider's developer name (for example `DropboxSign`) and whose **Webhook Secret** is the secret.
3. Choose who checks the provider when a notification arrives. Create a `PlatformEventSubscriberConfig` for the trigger `DocSignNoticeTrigger`, running as an integration user that has the DocBuilder Admin permission set and access to the provider's External Credential principal. Without it, the check runs as the Automated Process user, which cannot use the credential, and the update waits for the scheduled check instead.
4. In the provider's own settings, register this address for notifications:
   `https://<your site address>/services/apexrest/docbuilder/sign/<ProviderDeveloperName>?token=<secret>`

DocBuilder treats a notification only as a hint about which request changed. The public address raises an internal event; the check that follows asks the provider for the real status through its Named Credential, so a forged notification cannot mark a document as signed. Every rejected call gets the same empty `401` response.

## Organization limits

**Setup › Custom Settings › DocBuilder Settings** holds optional limits:

| Setting | Effect |
|---|---|
| Allowed Email Domains | Documents can only be emailed to these domains, e.g. `example.com, partner.org` |
| Org-Wide Email Address | A verified org-wide address that emailed documents are sent from |
| Max Email Recipients | Most recipients per document (default 10) |
| Max Bulk Records | Most records per bulk run (default 2000) |

Emailing documents needs the **DocBuilder Email Sender** permission set (or DocBuilder Admin). Bulk generation needs **DocBuilder Bulk Runner** (or DocBuilder Admin).

## Connect a provider that is not built in

Write one global Apex class that implements `DocBuilderSignProvider`:

```apex
global with sharing class AcmeSignProvider implements DocBuilderSignProvider {

    // The hidden text your provider looks for to place a field.
    // signerNumber starts at 1. fieldType is signature, date, name or initials.
    global String marker(Integer signerNumber, String fieldType) {
        return '[[' + fieldType + '_' + signerNumber + ']]';
    }

    global DocBuilderSign.SendResult send(DocBuilderSign.Envelope envelope) {
        Map<String, Object> payload = new Map<String, Object>{
            'title' => envelope.subject,
            'file' => EncodingUtil.base64Encode(envelope.file),
            'signers' => envelope.signers
        };
        HttpResponse response = DocBuilderSignHttp.callJson(envelope.config, 'POST', '/v1/requests', payload);
        DocBuilderSign.SendResult result = new DocBuilderSign.SendResult();
        result.externalId = (String) DocBuilderSignHttp.parse(response).get('id');
        return result;
    }

    global DocBuilderSign.StatusResult getStatus(DocBuilderSign.ProviderConfig config, String externalId) {
        Map<String, Object> answer = DocBuilderSignHttp.parse(DocBuilderSignHttp.call(config, 'GET', '/v1/requests/' + externalId, null, null));
        DocBuilderSign.StatusResult result = new DocBuilderSign.StatusResult();
        result.status = answer.get('state') == 'done' ? 'Completed' : 'Sent';   // Sent, Completed, Declined or Voided
        return result;
    }

    global Blob download(DocBuilderSign.ProviderConfig config, String externalId) {
        return DocBuilderSignHttp.call(config, 'GET', '/v1/requests/' + externalId + '/file', null, null).getBodyAsBlob();
    }

    global void cancel(DocBuilderSign.ProviderConfig config, String externalId, String reason) {
        DocBuilderSignHttp.call(config, 'DELETE', '/v1/requests/' + externalId, null, null);
    }
}
```

Then add a Signature Provider row naming the class and its Named Credential, and tick Active. The designer, the Generate dialog, the Flow action and the Apex API all pick it up with no further changes.

Notes:

- `envelope.config.settings` holds the row's Settings JSON, already parsed.
- `DocBuilderSignHttp` handles the Named Credential, error responses, JSON and multipart uploads. You do not have to use it.
- If your provider does not place fields from text in the document, return an empty string from `marker` and place them in `send` instead.
- `getStatus` may list each signer's own status (`Sent`, `Signed`, `Declined`) in `result.signers`. If it does not, all signers are marked Signed when the request is Completed.
- `download` may return null; the copy that was sent is then kept as the signed record.
- To receive instant updates, also implement `DocBuilderSignWebhook` on the same class.
- `DocBuilderSignMock` is the smallest complete example.

## Change what users see

**Button text and order.** Edit Button Label and Sort Order on the provider's row.

**Replace the signing form.** Build a screen flow and put its API name in Custom Screen Flow on the provider's row. The Generate dialog shows your flow in place of the built-in form when that provider is chosen. The flow must have three text input variables, which DocBuilder fills in:

| Variable | Contains |
|---|---|
| `recordId` | The record the user is on |
| `templateId` | The first template the user selected |
| `providerName` | The provider row's developer name |

Inside the flow, use the **Send Document for Signature** action to do the sending. A flow can contain any custom Lightning component, so this is also how you add a fully custom screen.

**Send without any screen.** Use the same action in a record-triggered flow, or call it from Apex:

```apex
DocBuilderSign.SendRequest request = new DocBuilderSign.SendRequest();
request.templateId = templateId;
request.recordId = opportunityId;
request.providerName = 'DocuSign';
Id signatureRequestId = DocBuilderSign.send(request);
```

`DocBuilderSign.refresh(signatureRequestId)` checks status on demand, and `DocBuilderSign.cancel(signatureRequestId, reason)` withdraws a request.

## Limits to know about

- Sending happens a few seconds after the user clicks, in the background.
- The built-in providers place fields using hidden white text in the signature areas. How large each provider draws a field from that text can differ; check a test document before going live.
- Signed copies are saved once, when the request completes. Partially signed copies are not stored.
