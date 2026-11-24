# DocBuilder

Native Salesforce document generation with optional e-signature. Templates are designed inside Salesforce in a
block-based designer (Word, Conga, DocuSign Gen and CPQ templates can be imported, but are converted, not used
as-is). They are rendered to HTML, converted to PDF by Salesforce, saved as Files on the record, and can be sent
for signature through Dropbox Sign, DocuSign, Adobe Acrobat Sign or any custom provider. "DocBuilder" is a
working name.

Read the guides in `docs/` before changing behaviour. They are the user-facing contract:
- `docs/user-guide.html`: generating and sending documents.
- `docs/admin-guide.html`: access, designer, conditions, Apex variables, tables, data sources, custom content,
  layout, versions, import/export, e-sign setup, limits, troubleshooting.
- `docs/developer-guide.html`: architecture, data model, **template JSON schema**, Apex API, Flow actions,
  data sources and extension interfaces, custom signature providers, components, security, testing, limits.
- `docs/esignature.md`: e-signature design notes.

**When you change behaviour, update the matching guide in the same change.** The three HTML guides share one
stylesheet and nav, so copy the existing markup patterns. Keep each guide's nav in the same order as its sections.

## Project layout

- SFDX project, `sourceApiVersion` 60.0, **no namespace**. The plan is an **unlocked package**; a managed or
  namespaced package was explicitly deferred. No package or Dev Hub is set up yet, so no package version exists.
- `force-app/`: everything that ships in the package (default directory).
- `org-setup/`: org-specific metadata, **not** packaged. Only the Quote "Generate Document" quick action.
- `samples/`: working examples of the extension points, **not** packaged. Contents:
  - `DocBuilderSampleProductSummary`: Custom content, Apex.
  - `DocBuilderSampleAccountVariables`: Apex variables.
  - `DocBuilderSampleOpenCasesCheck`: a single yes/no.
  - `DocBuilderSampleAccountCard`: a Visualforce page with its controller.

  Tests are in `DocBuilderSampleContentTest`. Deploy with `--source-dir samples`.
- `sfdx-project.json` sets `postInstallScript: DocBuilderInstall`. It only takes effect once package fields are added.

### Apex (`force-app/main/default/classes`)

| Area | Classes |
|---|---|
| Public API | `DocBuilder` (global, `generate()`, `generateInBackground()`), `DocBuilderFlowAction`, `DocBuilderSign` (global), `DocBuilderSignFlowAction` |
| Generation pipeline | `DocBuilderEngine` (orchestrates) → `DocBuilderPrepare` (clauses, translations, auto conditions) → `DocBuilderContext` (loads data and data sources, rules, calculations, formulas, Apex variables, formatting, snapshot) → `DocBuilderRenderer` (HTML for the PDF engine, watermarks, grouped tables, Custom content) |
| UI controllers | `DocBuilderController` (Generate button), `DocBuilderDesignerController` (designer: lifecycle, versions, describe, preview, `calcValues`, health `check`, translations, provider test, import, object and VF page lists, Apex class checks, watermark images) |
| Extension interfaces | `DocBuilderContentProvider` (Custom block HTML), `DocBuilderVariableProvider` (many typed values per class), `DocBuilderConditionProvider` (single yes/no, older), `DocBuilderContentRequest` (what each receives: recordId, objectName, settings, language) |
| Import | `DocBuilderImport` (matches imported merge fields to fields, by describe only), `DocBuilderImportSources` ("From this org": CPQ templates rebuilt as HTML, Conga/DocuSign Gen/OmniStudio attached files; standard-quote layout) |
| Bulk | `DocBuilderBulkJob` (chained Queueable, progress on `DocGenJob__c`) |
| Policy | `DocBuilderPolicy` (email recipient and domain limits, bulk size; reads the `DocBuilderSettings__c` hierarchy setting) |
| System-mode writes | `DocBuilderStore`: the **only** class that writes audit, delivery, job and signature records in system mode. This is deliberate; see the security notes. |
| E-signature | Interfaces `DocBuilderSignProvider` (required), `DocBuilderSignWebhook` and `DocBuilderSignCheck` (optional). Providers `DocBuilderSignDropbox`, `DocBuilderSignDocuSign`, `DocBuilderSignAdobe`, `DocBuilderSignMock`. Helpers `DocBuilderSignHttp`. Jobs `DocBuilderSignJob` (send), `DocBuilderSignSyncJob` + `DocBuilderSignSync` (15-minute status check, 4 cron jobs named `DocBuilder signature status :00/:15/:30/:45`). Webhooks `DocBuilderSignWebhookEndpoint` (public REST) → `DocSignNotice__e` → `DocSignNoticeTrigger` → `DocBuilderSignNotices` |
| Install and samples | `DocBuilderInstall` (post-install: schedules the status check, never fails the install), `DocBuilderSamples` (sample template installer) |
| Tests | `DocBuilderTest`, `DocBuilderDesignerTest`, `DocBuilderSignTest`, `DocBuilderSecurityTest`, `DocBuilderInstallTest`, `DocBuilderImportTest`, `DocBuilderSourcesTest` (data sources, Custom content, Apex variables, grouping); helper `DocBuilderTestUtil` |

### LWC (`force-app/main/default/lwc`)

- `docBuilderDesigner`: the Template Designer (~3.7k lines of JS). Layout:
  - left rail to add blocks;
  - the page;
  - right panel with Settings and Fields tabs. With no block selected, Settings shows the **Template settings
    menu** (`settingsPanel = 'menu'`): page, header/footer/watermark, data sources, calculated values,
    conditions (with Apex variables), signers, emails, name and languages, versions. A selected block shows
    "‹ Template settings" (Esc also works) to go back.
  - top bar: picker, New, Import, Export, Design/Preview/Translate, Check fields, Save draft, Activate.

  Features:
  - drag-to-arrange layout: up to 4 blocks per row, widths 10–100%;
  - numbered conditional parts;
  - formula bar with autocomplete and a live result (`calcValues`, debounced, ticketed so stale answers are dropped);
  - diagonal watermark drawing (`prepareWatermarkImages`).
- `docBuilderRule`: rule editor; fields are always picked from lists (object fields, related records, `calc:`
  values, `apex:` variables via `calc-names` / `apex-checks`), with value controls per type.
- `docBuilderFieldPicker`: reusable two-level field picker (field, or related record then field).
- `docBuilderImport` + `docBuilderImportParse`: Import wizard and its browser-side reader (.docx via
  `DecompressionStream('deflate-raw')`, HTML, text, DocBuilder export).
- `docBuilderGenerate`, `docBuilderGenerateAction`, `docBuilderGenerateModal`: the Generate Document flow.
- `docBuilderSignSend`, `docBuilderSignTracker`: send for signature and track status.
- `docBuilderSafeHtml`: shows previews **without innerHTML** (parses, allow-lists, imports nodes). Use it for any HTML preview.

### Data model

| Object | Purpose |
|---|---|
| `DocTemplate__c` | A template: base object, status, active version, languages, file name pattern |
| `DocTemplateVersion__c` | Body JSON per version (Draft, Active or Archived), max 131,072 chars. Activating archives the previous one; versions are never deleted |
| `DocClause__c` | Clause library for terms blocks |
| `DocTranslation__c` | Per-version, per-language text translations |
| `GeneratedDocument__c` | Audit record with `Snapshot_JSON__c` (≤130k chars) and `Template_Version__c`. Read-only for everyone in the UI |
| `DocDelivery__c` | Email delivery log |
| `DocGenJob__c` | Bulk job progress |
| `DocSignRequest__c`, `DocSigner__c` | Signature requests and their signers (`Error_Message__c`, `Error_Detail__c`) |
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

- `blocks[]`: each has `id`, `type` and optional `showIf`, `elseText`, `span` (integer 10–100, a percent of
  the page width), `beside` (joins the row above) and `align`. The renderer turns rows into a fixed-layout
  `<table class="cols">` because the PDF engine has no flexbox. The types:
  - `heading`, `text` (`rich` for HTML), `image`, `terms`, `signature`, `pagebreak`;
  - `table`: `source` (relationship, `Account.Contacts` or `ds:Name`), `columns` with `show`
    always|filled|rule, `rowFilter`, `orderBy`, `totals`, `groupBy`, `groupTotals`, `hideWhenEmpty`;
  - `custom`: `source` apex|visualforce, `className`/`settings` or `page`.
- Text tokens:
  - fields: `{{Field}}`, `{{Account.Name}}`, `{{Field|format}}`;
  - values: `{{calc:Name}}`, `{{ds:Name.Field}}` (data source's first row), `{{apex:Name}}`;
  - sections: `{{#if X}}…{{else}}…{{/if}}`, where X is a field path, `not Field`, `cond:Name`,
    `ds:Name.Field` or `apex:Name`.
- `conditions[]`: named rules. Entries with `"auto": true` and names `PartN` are created by the designer's
  conditional parts; it hides and prunes them, so don't rename them by hand.
- RULE = `{ logic, conditions: [{ field, op, value }] }`.
  - `op`: eq, ne, gt, ge, lt, le, contains, blank, notBlank.
  - `field`: a path, `calc:Name`, `ds:Name.Field` or `apex:Name`.
  - `logic`: like `1 AND (2 OR NOT 3)`.
  - Comparisons: dates as dates, numbers numerically, text case-insensitively.
- `calculations[]` of type `lookup` ("Text by value"): `{ field, cases: [{ value, text }], otherwise }`.
  - Gives text, kept in `ctx.textCalcs`; `calcValue()`, `formatCalc()` and `allCalcValues()` handle both kinds.
  - Formulas can't use it.
  - The rule editor gets text calc names via `text-calcs`.
- `calculations[]`: count, sum, avg, min, max over a `source` (relationship or `ds:Name`) with optional `filter`,
  or `formula` (`expression` with fields, `calc:Name`, `+ - * /`, comparisons giving 1/0, ROUND, ABS, CEILING,
  FLOOR, MIN, MAX, IF, AND, OR, NOT). A formula only sees calculations above it. Nesting capped at 40.
- `dataSources[]`: `{ name, object, filters: [{ field, op, from: value|record|list, value|recordField|list+listField }],
  match: all|any, orderBy, orderDirection, limit }`.
  - Max 10 per template, 500 rows each.
  - Loaded in order; unused ones aren't queried.
  - They're stored in `ctx.lists` under `ds:Name`, so tables, calcs, signers and the snapshot just work.
  - Code: `DocBuilderContext.listKey / collectDataSources / loadDataSources / dataSourceSoql`.
- `apexChecks[]` (Apex variables): `{ name, className, variable, type, settings }`.
  - A `DocBuilderVariableProvider` (`describeVariables` + `getValues`) runs once per class+settings per document.
  - A `DocBuilderConditionProvider` gives one yes/no.
  - Code: `DocBuilderContext.apexValue / apexCheck / checkApexChecks`.
- `page.watermark`: `text`, `showIf`, `direction` across|diagonal, `size` fit|large|medium|small,
  `shade` light|medium|dark, plus `imageId` / `draftImageId` / `imageKey` for diagonal images.
- Table totals over the table's own `source` are recomputed over the rows it shows (after `rowFilter`, and per
  group with `groupTotals`) by `DocBuilderContext.formatTableTotal`.

## Feature notes

- Versions: `listVersions`, `makeVersionLive` (rollback: archives the live version and re-checks fields first;
  the draft is untouched), `copyVersionToDraft` (replaces or creates the draft, copying translations).
- Import sources:
  - **File or paste.**
  - **From this org** (`DocBuilderImportSources`): CPQ, Conga, DocuSign Gen and OmniStudio, found by describe.
    **None of these packages is in `hpsandbox`**, so the CPQ query code (`loadCpq`) has never run against
    real records. Its conversion (`cpqTemplate`) is tested with sample maps, and the file-reading path is tested
    by pointing a tool at Account (`testObjects`). The class is at 77% coverage, below the 85% target, because
    of `loadCpq`. CPQ object and field names (`SBQQ__TemplateSection__c.SBQQ__Content__r`, `SBQQ__LineColumn__c`,
    `SBQQ__QuoteTerm__c`, …) come from general CPQ knowledge plus Trailhead, so check them in a CPQ org.
  - **Standard Salesforce quote:** a ready-made layout. Salesforce's standard quote templates can't be read:
    `QuoteTemplateRichTextData` doesn't support query.
- Syntax per tool (DocuSign Gen's syntax wasn't confirmed from official docs; it follows the `<# <Tag Select="XPath"/> #>`
  style seen in community threads):
  - Conga: MERGEFIELD / `TableStart:`.
  - Gen: `<# <Content Select=…/> #>`, `TableRow`, `Conditional`.
  - OmniStudio: `{{x}}`, `{{#list}}`, `{{#if}}`, `{{^x}}`.
  - CPQ: `{!quote.x}`, `{!template.x}`, `{!line.x}`.
- Import: merge fields become placeholders `\u0002n\u0003` pointing at `model.tokens[n]` until mapped.
  `DocBuilderDesignerController.importTemplate` creates a draft. Export is a `.docbuilder.json` with
  `format: 'docbuilder-template'`. Verified in a browser (Nov 2026) with pasted text and a Conga-style .docx
  (MERGEFIELDs, `TableStart:`, lists, page break, footer PAGE field). No automated test covers the Word XML walk
  or HTML path (they need DOMParser), so re-check in a browser after changing them.
- Custom content: Apex via `DocBuilderContentProvider`. Visualforce via `PageReference.getContent()`: it acts
  like a callout, so not after uncommitted DML; in tests it prints a placeholder. All output goes through
  `DocBuilderRenderer.cleanCode`. LWC and Aura can't be rendered into PDFs (no browser on the server).
- Diagonal watermarks: the PDF engine ignores CSS `transform` (tested with standard, `-fs-` and `-webkit-`), so
  the designer draws PNGs on a `<canvas>` at save time. `saveWatermarkImage` accepts PNG only and attaches the
  image to the template. The renderer places it as a centred square. Text with fields falls back to across the page.
- Sending checks the provider is switched on (`DocBuilderSign.isActive`). In tests the Test provider always
  counts as on, and `DocBuilderSign.testInactive` switches providers off.
- Designer controller methods added later use `userError()` so `AuraHandledException` messages can be asserted
  in tests (otherwise they read "Script-thrown exception").

## Security conventions (keep these; reviewers depend on them)

- Every class is `with sharing`. All SOQL is `WITH USER_MODE` or `Database.queryWithBinds(..., AccessLevel.USER_MODE)`.
  All DML is `insert/update/delete as user`. **The only exception is `DocBuilderStore`**, which writes
  system-managed records in system mode on purpose and is documented as such.
- Field paths from templates are validated by pattern before they go into SOQL. Data-source objects, fields and
  operators come from fixed lists or the schema, and every compared value is a bind variable.
- Lists are capped at 500 rows.
- Output HTML: every value is escaped with `escapeHtml4()` in the renderer. Widths are clamped integers.
- HTML from code (Apex/Visualforce) goes through `cleanCode`.
- LWC: no `innerHTML`, no `eval`, no `lwc:dom="manual"` writes except through `docBuilderSafeHtml`.
- Webhook endpoint: same 401 and empty body for every rejection; secrets are compared by HMAC digest; it trusts
  nothing in the payload. It only raises `DocSignNotice__e`, and the handler asks the provider for the real status.
- Parsers (`ExprParser`, `LogicParser` in `DocBuilderContext`) cap nesting depth, because a stack-depth
  overflow in Apex can't be caught.
- `DocBuilderDesignerController` is only in the Admin permission set. So only admins choose Apex classes and
  Visualforce pages, and `testProvider` may show provider error detail.
- Extension classes run as the user generating the document, inside the same governor limits.
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
  - Anonymous Apex files written by PowerShell `Out-File -Encoding utf8` start with a byte-order mark, which
    the compiler rejects. Write them with `-Encoding ascii`.
- Standard deploy (Windows PowerShell):
  ```
  sf project deploy start --source-dir force-app --source-dir samples --target-org <alias> `
    --test-level RunSpecifiedTests --tests DocBuilderTest --tests DocBuilderDesignerTest `
    --tests DocBuilderSignTest --tests DocBuilderSecurityTest --tests DocBuilderInstallTest `
    --tests DocBuilderImportTest --tests DocBuilderSourcesTest --tests DocBuilderSampleContentTest --wait 40 --json
  ```
- Coverage: `sf apex run test --class-names <each test class> --code-coverage --result-format json`.
  - Last full run (2026-11-23): **55 tests, all passing, 94% overall.** Every class with code was at ≥85%; the
    lowest were `DocBuilderSignWebhookEndpoint` 85%, `DocBuilderSignJob` 89%, `DocBuilderContext` 91%.
    Added since: `DocBuilderImportSources` at 77%, the one class below 85%; its CPQ queries need CPQ installed.
  - `DocBuilderContentRequest` shows 0% because it has no executable lines, which is fine.
  - Every new class needs its own tests, and deploys fail below 75% per class.
  - Use `@TestVisible` hooks to cover catch branches; see `DocBuilderInstall.simulateFailure`.
- `RunLocalTests` in `hpsandbox` also runs `InboundCsvEmailHandlerTest`, which fails. That class is **not part
  of DocBuilder** (it isn't in this folder), so ignore it.
- Callouts in tests go through `HttpCalloutMock`s in `DocBuilderSignTest`. The `TestProvider` / `DocBuilderSignMock`
  path needs no callouts.

## Code gotchas found the hard way

- **Never name an LWC component method `render`** (or another lifecycle hook). `render()` must return a template.
  A helper called `render` made the Import wizard draw nothing (Nov 2026). Node tests that call the class
  directly can't catch this.
- **Browser caching hides new LWC versions.** After a deploy, Lightning can keep serving the old component (seen
  Nov 2026: new controls missing until the cache was cleared). Hard-refresh, or turn off Setup › Session Settings ›
  "Enable secure and persistent browser caching" in dev orgs, before deciding a UI change "doesn't work".
- **LWC regex literals containing `/` inside a character class broke the LWC compiler.** Build such patterns with
  `new RegExp('...')` strings (see `FX_TOKEN`, `FX_OPERATOR` in `docBuilderDesigner.js`).
- LWC templates: a literal `{` inside text or an attribute is parsed as a binding. Put such text in a getter.
- Apex: `inner` is a reserved word. Interfaces can't contain inner classes, which is why
  `DocBuilderContentRequest` is its own class. Avoid `while (true)` with returns inside; it can trip
  "unreachable statement", so use a `Boolean more` loop.
- Long text fields (e.g. `Translated_Text__c`) can't be filtered in SOQL.
- The formula field-collection regex uses a possessive quantifier plus a negative lookahead
  (`[A-Za-z_][A-Za-z0-9_.]*+(?!\s*\()`) so function names aren't collected as fields.
- Don't bind `onclick` to handlers that mark the template dirty on form inputs.
- PDF rendering supports CSS 2.1 plus paged media only: no flexbox, grid or transforms in rendered documents.
  - `position:fixed` elements repeat on every page and are placed from the top-left of the page's **content
    area**.
  - Percentage heights and table-cell vertical centring don't work.
  - That's why watermark positions are calculated in mm (`DocBuilderRenderer.pageBox` / `watermarkHtml`).
- Visualforce trims spaces before `apex:outputText`; put literal text inside the value (`value="About {!x}"`).
- Permission set and group descriptions have a 255-character limit.

## Verifying changes

- Rendering: build the HTML with `DocBuilderRenderer` in Anonymous Apex, `Blob.toPdf` it into a ContentVersion,
  download it with the REST API, look at it, then delete the test file.
- UI: drive headless Edge over the DevTools protocol.
  - Sign in with `sf org open --url-only`.
  - Walk synthetic shadow roots to find elements.
  - Dispatch `change` CustomEvents on lightning inputs.
  - Use `DOM.setFileInputFiles` for file pickers.
  - Capture `Runtime.exceptionThrown`.
  - Use a fresh browser profile each run, or Salesforce serves cached components.
  - Delete any records it creates.

  The script lived in the session scratchpad, which gets cleared, so expect to rebuild it.

## E-signature status in the author's org (2026-11-23)

- Dropbox Sign: API key set, connection test passes, provider row **active** in **test mode**
  (`{"testMode":true}`). TestProvider is switched **off** (changed 2026-11-19, in the org only; packaged
  defaults are unchanged).
- Still to do in that org:
  - run `DocBuilderSignSync.schedule();` (not scheduled; the install script only runs on a real package install);
  - optionally set up the Site, webhook secret and `PlatformEventSubscriberConfig` for instant updates.
- An unassigned leftover permission set `DocBuilder_DropboxSign_Access` still exists in that org. It was
  replaced by `DocBuilder_ESignature_Access` and is no longer in source.

## Ideas discussed but not built

- A "Save API key" box in the designer's provider settings (via `ConnectApi.NamedCredentials`), so admins never
  open Setup › Named Credentials.
- Packaged shell credentials for DocuSign and Adobe Sign, so their principals can join `DocBuilder_ESignature_Access`.
- A pick-list for table column fields (the column Field box is still free text; `docBuilderFieldPicker` could replace it).
- Namespaced or managed packaging. If it's done, make `DocSignProvider__mdt.Active__c` and `Config_JSON__c`
  subscriber-editable, and namespace the `$Credential` merge field in the named credential formula.

## Working agreements with the owner

- Not a git repo with commits yet. Don't commit or push unless asked.
- Use plain language in UI text and docs; admins aren't developers.
- Keep the guides in `docs/` in sync with behaviour changes.
- Check UI changes in a real browser before calling them done; Node-only checks have missed real bugs.
