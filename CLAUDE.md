# DocBuilder

Native Salesforce document generation with optional e-signature. Templates are designed inside Salesforce
(no Word uploads), rendered to HTML, converted to PDF by Salesforce, saved as Files on the record, and can be
sent for signature through Dropbox Sign, DocuSign, Adobe Acrobat Sign or any custom provider.
"DocBuilder" is a working name.

Read the guides in `docs/` before changing behaviour. They are the user-facing contract:
- `docs/user-guide.html`: generating and sending documents.
- `docs/admin-guide.html`: access, designer, layout, conditions, formulas, e-sign setup, limits, troubleshooting.
- `docs/developer-guide.html`: architecture, data model, **template JSON schema**, Apex API, Flow actions,
  custom signature providers, formula grammar, testing.
- `docs/esignature.md`: e-signature design notes.

**When you change behaviour, update the matching guide in the same change.** The three HTML guides share one
stylesheet and nav, so copy the existing markup patterns.

## Project layout

- SFDX project, `sourceApiVersion` 60.0, **no namespace**. The plan is an **unlocked package**; a managed or
  namespaced package was explicitly deferred. No package or Dev Hub is set up yet, so no package version exists.
- `force-app/`: everything that ships in the package (default directory).
- `org-setup/`: org-specific metadata that is **not** packaged. Currently only the Quote "Generate Document"
  quick action.
- `sfdx-project.json` sets `postInstallScript: DocBuilderInstall`. It only takes effect once package fields
  are added.

### Apex (`force-app/main/default/classes`)

| Area | Classes |
|---|---|
| Public API | `DocBuilder` (global, `generate()`), `DocBuilderFlowAction`, `DocBuilderSign` (global), `DocBuilderSignFlowAction` |
| Generation pipeline | `DocBuilderEngine` (orchestrates) → `DocBuilderPrepare` (clauses, translations, auto conditions) → `DocBuilderContext` (loads data, rules, calculations, formulas, formatting) → `DocBuilderRenderer` (HTML for the PDF engine) |
| UI controllers | `DocBuilderController` (Generate button), `DocBuilderDesignerController` (Template Designer: lifecycle, describe, preview, `calcValues`, health `check`, translations, provider test) |
| Bulk | `DocBuilderBulkJob` (chained Queueable, progress on `DocGenJob__c`) |
| Policy | `DocBuilderPolicy` (email recipient and domain limits, bulk size; reads the `DocBuilderSettings__c` hierarchy setting) |
| System-mode writes | `DocBuilderStore`: the **only** class that writes audit, delivery, job and signature records in system mode. This is deliberate; see the security notes. |
| E-signature | Interfaces `DocBuilderSignProvider` (required), `DocBuilderSignWebhook` and `DocBuilderSignCheck` (optional). Providers `DocBuilderSignDropbox`, `DocBuilderSignDocuSign`, `DocBuilderSignAdobe`, `DocBuilderSignMock`. Helpers `DocBuilderSignHttp`. Jobs `DocBuilderSignJob` (send), `DocBuilderSignSyncJob` + `DocBuilderSignSync` (15-minute status check, 4 cron jobs named `DocBuilder signature status :00/:15/:30/:45`). Webhooks `DocBuilderSignWebhookEndpoint` (public REST) → `DocSignNotice__e` → `DocSignNoticeTrigger` → `DocBuilderSignNotices` |
| Install and samples | `DocBuilderInstall` (post-install: schedules the status check, never fails the install), `DocBuilderSamples` |
| Tests | `DocBuilderTest`, `DocBuilderDesignerTest`, `DocBuilderSignTest`, `DocBuilderSecurityTest`, `DocBuilderInstallTest`, helper `DocBuilderTestUtil` |

### LWC (`force-app/main/default/lwc`)

- `docBuilderDesigner`: the Template Designer. A large component (~2.5k lines of JS). Features:
  - drag-to-arrange layout: up to 4 blocks per row, widths 10–100%, divider drag and arrow keys;
  - numbered conditional parts (click text to make it conditional, rule editor in Settings);
  - a formula bar with autocomplete and a live result (`calcValues`, 700 ms debounce, ticketed so stale answers are dropped).
- `docBuilderRule`: rule editor with field pickers. It covers lookups (`>Rel` then a field on the related
  record), calculated values, and picklist, boolean, date, number and text value controls. Rules are always
  picked from lists, never typed, so they can't break by typos.
- `docBuilderGenerate`, `docBuilderGenerateAction`, `docBuilderGenerateModal`: the Generate Document flow.
- `docBuilderSignSend`, `docBuilderSignTracker`: send for signature and track status.
- `docBuilderSafeHtml`: shows previews **without innerHTML** (parses, then imports nodes). Use it for any HTML preview.

### Data model

| Object | Purpose |
|---|---|
| `DocTemplate__c` | A template: base object, status, active version, languages, file name pattern |
| `DocTemplateVersion__c` | Body JSON per version (Draft, Active or Archived). Activating archives the previous one; versions are never deleted |
| `DocClause__c` | Clause library for terms blocks |
| `DocTranslation__c` | Per-version, per-language text translations |
| `GeneratedDocument__c` | Audit record with a data snapshot (≤130k chars). Read-only for everyone in the UI |
| `DocDelivery__c` | Email delivery log |
| `DocGenJob__c` | Bulk job progress |
| `DocSignRequest__c`, `DocSigner__c` | Signature requests and their signers |
| `DocSignProvider__mdt` | Custom metadata, one row per provider: Apex class, named credential name, button label, screen style, custom flow, `Config_JSON__c` (e.g. `{"testMode":true}`), `Active__c`, sort order. **No secrets.** Packaged rows: DropboxSign (inactive), DocuSign, AdobeSign, TestProvider (active) |
| `DocSignSecret__c` | List custom setting: the **inbound webhook password** per provider (Name = provider developer name). Not an API key. It exists because a credential's value can't be read by Apex for comparing inbound calls, and custom metadata is readable by too many users |
| `DocBuilderSettings__c` | Hierarchy custom setting for org limits (allowed email domains, max recipients, org-wide email, max bulk records) |
| `DocSignNotice__e` | Platform event raised by the webhook |

API keys live **only** in External Credentials (encrypted, never readable by Apex).

### Access

| Name | Type | Contents |
|---|---|---|
| DocBuilder Admins | Permission set group | DocBuilder_Admin + DocBuilder_ESignature_Access |
| DocBuilder Users | Permission set group | DocBuilder_User + DocBuilder_ESignature_Access |
| DocBuilder_Email_Sender, DocBuilder_Bulk_Runner | Permission sets | Deliberately opt-in add-ons for users. Admin already has both custom permissions |
| DocBuilder_ESignature_Access | Permission set | Principal access to every **packaged** credential (today only `DocBuilder_DropboxSign-DropboxSignKey`). Subscriber-created credentials, such as DocuSign or Adobe OAuth, can't be referenced here and need their own permission set |

Packaged Dropbox Sign credential:
- External Credential `DocBuilder_DropboxSign`: Custom protocol, Named Principal `DropboxSignKey`.
- Named Credential `DocBuilder_DropboxSign`: `https://api.hellosign.com`, Generate Authorization Header off,
  Allow Formulas in HTTP Header on, and header
  `Authorization = {!'Basic ' & BASE64ENCODE(BLOB($Credential.DocBuilder_DropboxSign.ApiKey & ':'))}`.
- After install, the admin adds the authentication parameter **`ApiKey`** to the principal (the name must match exactly).

## Template body JSON (summary; full schema in `docs/developer-guide.html`)

- `blocks[]`: each has `id`, `type` (text, table, terms, signature, image, pagebreak, …) and `span`
  (an integer 10–100, a percent of the page width). `beside: true` joins the row of the block above. The renderer
  turns rows into a fixed-layout `<table class="cols">` because the PDF engine has no flexbox.
- Text uses merge fields like `{{Field}}`, `{{Account.Name}}` and `{{calc:Name}}`. Conditionals use
  `{{#if Cond}}…{{else}}…{{/if}}`; a simple not-blank test can be `{{#if Field}}` / `{{#if not Field}}`.
- `conditions[]`: named rules (`conditions[]` of field, operator and value, plus optional `logic` like `1 AND (2 OR NOT 3)`).
  Conditions with `"auto": true` and names `PartN` are created by the designer's conditional parts. The designer
  hides and prunes them; don't rename them by hand.
- `calculations[]`: `type` is count, sum, avg, min, max or formula. Aggregates have `source` (a child relationship),
  `field` and optional `filter` (a rule). Formulas have `expression` with numbers, fields, `calc:Name`,
  `+ - * /`, comparisons (= == != <> < <= > >=, giving 1/0) and the functions ROUND(x[,n]), ABS, CEILING,
  FLOOR, MIN, MAX, IF(c,a,b), AND, OR, NOT. A formula can only use calculations defined above it.
  Nesting is capped at 40 (`MAX_NESTING`).
- Table totals: when a total's calculation sums the **same list** the table shows, it is recomputed over the
  rows the table actually shows, after its row filter (`DocBuilderContext.formatTableTotal`). Formulas and
  totals over other lists print their document-wide value.

## Security conventions (keep these; reviewers depend on them)

- Every class is `with sharing`. All SOQL is `WITH USER_MODE` or `Database.queryWithBinds(..., AccessLevel.USER_MODE)`.
  All DML is `insert/update/delete as user`. **The only exception is `DocBuilderStore`**, which writes
  system-managed records in system mode on purpose and is documented as such.
- Field paths from templates are validated by pattern before they are put into SOQL. Child lists are capped at 500 rows.
- Output HTML: every value is escaped with `escapeHtml4()` in the renderer. Widths are clamped integers.
- LWC: no `innerHTML`, no `eval`, no `lwc:dom="manual"` writes except through `docBuilderSafeHtml`.
- Webhook endpoint: same 401 and empty body for every rejection; secrets are compared by HMAC digest; it trusts
  nothing in the payload. It only raises `DocSignNotice__e`, and the handler asks the provider for the real status.
- Parsers (`ExprParser`, `LogicParser` in `DocBuilderContext`) cap nesting depth, because a stack-depth
  overflow in Apex can't be caught.
- `DocBuilderDesignerController` is only in the Admin permission set, which is why `testProvider` may show
  provider error detail.
- Never put API keys or webhook secrets in source, test data that ships, chat, or logs.

## Building and deploying

- Org alias used by the original author: **`hpsandbox`** (a developer org). Deploy only to an org the
  current user names. Don't deploy to other connected orgs, which may be client sandboxes.
- The installed CLI was old (`@salesforce/cli` 1.86.7). Known quirks:
  - `sf project deploy start` may end with `Missing message metadata.transfer:Finalizing for locale en_US`
    even when the deploy worked. Confirm with `sf project deploy report --job-id <id> --json`; on that version
    `report` takes no `--target-org` or `--wait`.
  - `sf org assign permset` doesn't handle permission set groups. Insert a `PermissionSetAssignment` with
    `PermissionSetGroupId` instead.
- Standard deploy (Windows PowerShell):
  ```
  sf project deploy start --source-dir force-app --target-org <alias> --test-level RunSpecifiedTests `
    --tests DocBuilderTest --tests DocBuilderDesignerTest --tests DocBuilderSignTest `
    --tests DocBuilderSecurityTest --tests DocBuilderInstallTest --wait 40 --json
  ```
- Full run with coverage: `sf apex run test --target-org <alias> --test-level RunLocalTests --code-coverage --result-format json --wait 40`.
  In `hpsandbox`, `InboundCsvEmailHandlerTest` fails. That class is **not part of DocBuilder** (it isn't in this
  folder), so ignore it for DocBuilder work.
- Every DocBuilder class should stay at **≥85% coverage**, as it was at the last check (Nov 2026: 85–100%, with
  WebhookEndpoint the lowest). Every new class needs its own tests, and deploys fail below 75% per class.
  Use `@TestVisible` hooks to cover catch branches; see `DocBuilderInstall.simulateFailure`.
- Callouts in tests go through `HttpCalloutMock`s in `DocBuilderSignTest`. The `TestProvider` / `DocBuilderSignMock`
  path needs no callouts.

## Code gotchas found the hard way

- **LWC regex literals containing `/` inside a character class broke the LWC compiler.** Build such patterns with
  `new RegExp('...')` strings (see `FX_TOKEN`, `FX_OPERATOR` in `docBuilderDesigner.js`).
- In Apex, avoid `while (true)` with returns inside; it can trip "unreachable statement". Use a `Boolean more` loop.
- The formula field-collection regex uses a possessive quantifier plus a negative lookahead
  (`[A-Za-z_][A-Za-z0-9_.]*+(?!\s*\()`) so function names aren't collected as fields.
- Don't bind `onclick` to handlers that mark the template dirty on form inputs (the designer's formula input
  only uses input, keydown and blur).
- PDF rendering supports CSS 2.1 plus paged media only: no flexbox or grid in rendered documents (the designer UI may use them).
- In the PDF engine, `position:fixed` elements repeat on every page and are placed from the top-left of the
  page's **content area** (inside the margins). It ignores `transform` and percentage heights, and table-cell
  vertical centring doesn't work there. That's why the watermark position is calculated in mm from the page size
  and margins (`DocBuilderRenderer.pageBox` / `watermarkHtml`). To check a rendering change, generate a PDF with
  `Blob.toPdf` in Anonymous Apex, download it, look at it, then delete the test file.
- Permission set and group descriptions have a 255-character limit.

## E-signature status in the author's org (Nov 2026)

- Dropbox Sign API key is set and the connection test passes in **test mode** (`{"testMode":true}`).
- Still to do in that org:
  - activate the DropboxSign provider row and deactivate TestProvider;
  - run `DocBuilderSignSync.schedule();` (the install script only runs on a real package install, not on deploys);
  - optionally create a `PlatformEventSubscriberConfig` for `DocSignNoticeTrigger` to get instant webhook updates.
- An unassigned leftover permission set `DocBuilder_DropboxSign_Access` may still exist in that org. It was replaced
  by `DocBuilder_ESignature_Access` and is no longer in source.

## Ideas discussed but not built

- A "Save API key" box in the designer's provider settings (via `ConnectApi.NamedCredentials`), so admins never
  open Setup › Named Credentials.
- Packaged shell credentials for DocuSign and Adobe Sign, so their principals can join `DocBuilder_ESignature_Access`.
- Namespaced or managed packaging. If it's done, make `DocSignProvider__mdt.Active__c` and `Config_JSON__c`
  subscriber-editable, and namespace the `$Credential` merge field in the named credential formula.

## Working agreements with the owner

- Not a git repo with commits yet. Don't commit or push unless asked.
- Use plain language in UI text and docs; admins aren't developers.
- Keep the guides in `docs/` in sync with behaviour changes.
