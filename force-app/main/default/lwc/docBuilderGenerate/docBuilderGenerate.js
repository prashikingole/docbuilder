import { renderSafe } from 'c/docBuilderSafeHtml';
import { LightningElement, api, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getTemplates from '@salesforce/apex/DocBuilderController.getTemplates';
import previewTemplate from '@salesforce/apex/DocBuilderController.preview';
import generateDocument from '@salesforce/apex/DocBuilderController.generate';
import getSignOptions from '@salesforce/apex/DocBuilderController.getSignOptions';
import sendForSignature from '@salesforce/apex/DocBuilderController.sendForSignature';

const SIGN_PREFIX = 'sign:';

export default class DocBuilderGenerate extends NavigationMixin(LightningElement) {
    @api recordId;

    templates = [];
    selectedIds = [];
    viewId;
    language = '';
    draft = false;

    // What the main button does: 'generate', 'email', or 'sign:<provider>'
    action = 'generate';
    emailTo = '';
    emailSubject = '';
    emailBody = '';

    providers = [];
    canEmail = false;
    signers = [];
    signSubject = '';
    signMessage = '';
    signRequest;

    loaded = false;
    loading = false;
    result;
    error;
    previewHtml;
    previewError;
    renderedPreview;

    @wire(getTemplates, { recordId: '$recordId' })
    wiredTemplates({ data, error }) {
        if (data) {
            this.templates = data;
            this.selectedIds = data.length ? [data[0].Id] : [];
            this.viewId = this.selectedIds[0];
            this.loaded = true;
            this.refreshPreview();
            this.loadSignOptions();
        } else if (error) {
            this.error = this.messageOf(error);
            this.loaded = true;
        }
    }

    renderedCallback() {
        const host = this.template.querySelector('.preview-body');
        if (host && this.renderedPreview !== this.previewHtml) {
            renderSafe(host, this.previewHtml);
            this.renderedPreview = this.previewHtml;
        }
    }

    // ---------- Templates and options ----------

    get templateOptions() {
        return this.templates.map((t) => ({
            label: t.Active_Version__r ? `${t.Name} (version ${t.Active_Version__r.Version_Number__c})` : t.Name,
            value: t.Id
        }));
    }

    get hasTemplates() {
        return this.templates.length > 0;
    }

    get noTemplates() {
        return this.loaded && this.templates.length === 0;
    }

    get selected() {
        // Keep the order templates are listed in, which is the order they are combined in.
        return this.templates.filter((t) => this.selectedIds.includes(t.Id));
    }

    get languageOptions() {
        const codes = new Set();
        this.selected.forEach((t) => {
            (t.Languages__c || '')
                .split(',')
                .map((l) => l.trim())
                .filter((l) => l && l !== t.Default_Language__c)
                .forEach((l) => codes.add(l));
        });
        return [{ label: 'Default language', value: '' }, ...[...codes].sort().map((l) => ({ label: l, value: l }))];
    }

    get hasLanguages() {
        return this.languageOptions.length > 1;
    }

    get viewTabs() {
        return this.selected.map((t) => ({ id: t.Id, label: t.Name, variant: t.Id === this.viewId ? 'brand' : 'neutral' }));
    }

    get hasSeveral() {
        return this.selected.length > 1;
    }

    // ---------- What to do ----------

    /** Every provider an admin has switched on becomes its own choice, labelled as they named it. */
    get actionOptions() {
        const options = [{ label: 'Generate the PDF', value: 'generate' }];
        // Shown only to users allowed to email documents; the server enforces the same rule.
        if (this.canEmail) {
            options.push({ label: 'Generate and send by email', value: 'email' });
        }
        this.providers.forEach((p) => options.push({ label: p.label, value: SIGN_PREFIX + p.name }));
        return options;
    }

    get isEmail() {
        return this.action === 'email';
    }

    get isSign() {
        return this.action.startsWith(SIGN_PREFIX);
    }

    get provider() {
        return this.isSign ? this.providers.find((p) => SIGN_PREFIX + p.name === this.action) : null;
    }

    /** A provider can replace the built-in signing form with its own screen flow. */
    get customFlow() {
        return this.provider && this.provider.customFlow ? this.provider.customFlow : null;
    }

    get showBuiltInSign() {
        return this.isSign && !this.customFlow && this.signStyle === 'form';
    }

    get flowInputs() {
        return [
            { name: 'recordId', type: 'String', value: this.recordId },
            { name: 'templateId', type: 'String', value: this.selected.length ? this.selected[0].Id : '' },
            { name: 'providerName', type: 'String', value: this.provider ? this.provider.name : '' }
        ];
    }

    get showDraftOption() {
        return !this.isSign;
    }

    get signerRows() {
        return this.signers.map((s, index) => ({ ...s, index, key: index, title: s.role || `Signer ${index + 1}` }));
    }

    get noSigners() {
        return this.isSign && !this.customFlow && this.signers.length === 0;
    }

    get signerMissingEmail() {
        return this.isSign && this.signers.some((s) => !s.email || !s.email.trim());
    }

    get emailMissing() {
        return this.isEmail && !this.emailTo.trim();
    }

    get cannotGo() {
        return this.loading || !this.selected.length || this.emailMissing || (this.showBuiltInSign && (this.noSigners || this.signerMissingEmail));
    }

    get goLabel() {
        if (this.needsSignScreen) {
            return 'Continue to signing';
        }
        if (this.isSign) {
            return 'Send for signature';
        }
        return this.isEmail ? 'Generate and send' : 'Generate PDF';
    }

    get summary() {
        const count = this.selected.length;
        if (!count) {
            return 'Choose at least one template.';
        }
        const parts = [count === 1 ? this.selected[0].Name : `${count} templates combined into one PDF`];
        if (this.language) {
            parts.push(`language ${this.language}`);
        }
        if (this.isSign) {
            parts.push(`${this.signers.length} signer${this.signers.length === 1 ? '' : 's'}`);
            parts.push('signed copy saved to this record when complete');
        } else {
            if (this.draft) {
                parts.push('draft watermark');
            }
            parts.push('saved to Files on this record');
            if (this.isEmail && this.emailTo.trim()) {
                parts.push(`emailed to ${this.emailTo.trim()}`);
            }
        }
        return parts.join(' · ');
    }

    get showForm() {
        return this.hasTemplates && !this.result && !this.signRequest && !this.showSignScreen;
    }

    get showMainButton() {
        return this.showForm && !this.customFlow;
    }

    // ---------- Handlers ----------

    handleTemplates(event) {
        this.selectedIds = event.detail.value;
        if (!this.selectedIds.includes(this.viewId)) {
            this.viewId = this.selected.length ? this.selected[0].Id : undefined;
        }
        if (!this.languageOptions.some((o) => o.value === this.language)) {
            this.language = '';
        }
        this.refreshPreview();
        this.loadSignOptions();
    }

    handleView(event) {
        this.viewId = event.target.dataset.id;
        this.refreshPreview();
    }

    handleLanguage(event) {
        this.language = event.detail.value;
        this.refreshPreview();
    }

    handleAction(event) {
        this.action = event.detail.value;
        this.error = undefined;
    }

    handleCheck(event) {
        this[event.target.dataset.field] = event.target.checked;
    }

    handleText(event) {
        this[event.target.dataset.field] = event.detail.value;
    }

    handleSigner(event) {
        const index = Number(event.target.dataset.index);
        const prop = event.target.dataset.prop;
        this.signers = this.signers.map((s, i) => (i === index ? { ...s, [prop]: event.detail.value } : s));
    }

    async loadSignOptions() {
        const first = this.selected[0];
        if (!first || !this.recordId) {
            return;
        }
        try {
            const options = await getSignOptions({ templateId: first.Id, recordId: this.recordId });
            this.providers = options.providers || [];
            this.canEmail = options.canEmail === true;
            // The template's wording prefills the boxes; anything the user has already typed is kept.
            this.emailSubject = this.emailSubject || options.emailSubject || '';
            this.emailBody = this.emailBody || options.emailBody || '';
            this.signSubject = this.signSubject || options.signSubject || '';
            this.signMessage = this.signMessage || options.signMessage || '';
            if (this.action === 'email' && !this.canEmail) {
                this.action = 'generate';
            }
            this.signers = (options.signers || []).map((s) => ({ ...s }));
            if (this.isSign && !this.provider) {
                this.action = 'generate';
            }
        } catch (e) {
            this.providers = [];
        }
    }

    async refreshPreview() {
        this.previewError = undefined;
        if (!this.viewId || !this.recordId) {
            this.previewHtml = undefined;
            return;
        }
        try {
            this.previewHtml = await previewTemplate({ templateId: this.viewId, recordId: this.recordId, language: this.language || null });
        } catch (e) {
            this.previewHtml = undefined;
            this.previewError = this.messageOf(e);
        }
    }

    async go() {
        if (this.needsSignScreen) {
            this.error = undefined;
            this.signScreenOpen = true;
            return;
        }
        this.loading = true;
        this.error = undefined;
        try {
            if (this.isSign) {
                const requestId = await sendForSignature({
                    templateIds: this.selected.map((t) => t.Id),
                    recordId: this.recordId,
                    language: this.language || null,
                    providerName: this.provider.name,
                    signersJson: JSON.stringify(this.signers.map((s, i) => ({ role: s.role, name: s.name, email: s.email, routingOrder: i + 1 }))),
                    subject: this.signSubject || null,
                    message: this.signMessage || null
                });
                this.signRequest = { Id: requestId };
                return;
            }
            const res = await generateDocument({
                templateIds: this.selected.map((t) => t.Id),
                recordId: this.recordId,
                language: this.language || null,
                draft: this.draft,
                emailTo: this.isEmail ? this.emailTo : null,
                emailSubject: this.isEmail ? this.emailSubject : null,
                emailBody: this.isEmail ? this.emailBody : null
            });
            if (res.success) {
                this.result = res;
            } else {
                this.error = res.errorMessage || 'The document could not be generated.';
            }
        } catch (e) {
            this.error = this.messageOf(e);
        } finally {
            this.loading = false;
        }
    }

    // ---------- After sending for signature ----------

    get signRequestId() {
        return this.signRequest ? this.signRequest.Id : null;
    }

    // ---------- Which signing screen ----------

    signStyleChoice;
    signScreenOpen = false;

    /** The user's last choice wins; otherwise the provider's default. */
    get signStyle() {
        if (this.signStyleChoice) {
            return this.signStyleChoice;
        }
        let stored;
        try {
            stored = window.localStorage.getItem('docbuilder.signStyle');
        } catch (e) {
            stored = null;
        }
        if (['form', 'steps', 'desk'].includes(stored)) {
            return stored;
        }
        return (this.provider && this.provider.style) || 'form';
    }

    setSignStyle(style) {
        this.signStyleChoice = style;
        try {
            window.localStorage.setItem('docbuilder.signStyle', style);
        } catch (e) {
            // Remembering the choice is a convenience; the dialog works without it.
        }
    }

    /** Guided steps and the signing desk open as their own full-size screen. */
    get needsSignScreen() {
        return this.isSign && !this.customFlow && this.signStyle !== 'form';
    }

    get showSignScreen() {
        return this.needsSignScreen && this.signScreenOpen && !this.result && !this.signRequest;
    }

    get selectedTemplateIds() {
        return this.selected.map((t) => t.Id);
    }

    get documentName() {
        const count = this.selected.length;
        return count === 1 ? this.selected[0].Name : `${count} templates`;
    }

    get providerLabel() {
        return this.provider ? this.provider.label.replace(/^Send (with|for signature with)\s+/i, '') : '';
    }

    handleUseSteps() {
        this.setSignStyle('steps');
        this.signScreenOpen = true;
    }

    handleUseDesk() {
        this.setSignStyle('desk');
        this.signScreenOpen = true;
    }

    handleStyleChange(event) {
        this.setSignStyle(event.detail.style);
        if (event.detail.style === 'form') {
            this.signScreenOpen = false;
        }
    }

    handleSignBack() {
        this.signScreenOpen = false;
    }

    handleSignSent(event) {
        this.signRequest = { Id: event.detail.requestId };
        this.signScreenOpen = false;
    }

    openSignRequest() {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: this.signRequest.Id, actionName: 'view' }
        });
        this.close();
    }

    handleFlowStatus(event) {
        if (event.detail.status === 'FINISHED' || event.detail.status === 'FINISHED_SCREEN') {
            this.close();
        }
    }

    // ---------- After generating ----------

    get resultEmail() {
        return this.result && this.result.emailStatus ? this.result.emailStatus : '';
    }

    openFile() {
        this[NavigationMixin.Navigate]({
            type: 'standard__namedPage',
            attributes: { pageName: 'filePreview' },
            state: { selectedRecordId: this.result.contentDocumentId }
        });
        this.close();
    }

    openDocumentRecord() {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: this.result.documentId, actionName: 'view' }
        });
        this.close();
    }

    again() {
        this.result = undefined;
        this.signRequest = undefined;
        this.signScreenOpen = false;
        this.renderedPreview = undefined;
    }

    close() {
        // The modal (or any other host) closes itself when it hears this.
        this.dispatchEvent(new CustomEvent('close'));
    }

    messageOf(error) {
        if (error && error.body && error.body.message) {
            return error.body.message;
        }
        return error && error.message ? error.message : 'Something went wrong.';
    }
}
