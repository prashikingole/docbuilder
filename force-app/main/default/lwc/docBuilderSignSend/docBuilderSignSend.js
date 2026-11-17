import { renderSafe } from 'c/docBuilderSafeHtml';
import { LightningElement, api } from 'lwc';
import sendForSignature from '@salesforce/apex/DocBuilderController.sendForSignature';

const STEPS = [
    { number: 1, label: 'Document' },
    { number: 2, label: 'Signers' },
    { number: 3, label: 'Message' },
    { number: 4, label: 'Review and send' }
];

/**
 * The full-size "send for signature" screen, in two layouts:
 *   steps: a guided wizard (signers, message, review)
 *   desk:  one screen with the document on the left, colour-matched to the signers on the right
 * Fires "sent" with detail.requestId, "back" to return to the options, and "stylechange" to switch layout.
 */
export default class DocBuilderSignSend extends LightningElement {
    @api recordId;
    @api templateIds = [];
    @api language;
    @api providerName;
    @api providerLabel;
    @api documentName;
    @api variant = 'desk';

    /** The template's wording for this record, shown until the user types their own. */
    @api
    get initialSubject() {
        return this.subject;
    }
    set initialSubject(value) {
        if (!this.subject && value) {
            this.subject = value;
        }
    }

    @api
    get initialMessage() {
        return this.message;
    }
    set initialMessage(value) {
        if (!this.message && value) {
            this.message = value;
        }
    }

    _signers = [];
    _previewHtml;
    renderedPreview;

    together = false;
    subject = '';
    message = '';
    step = 2;
    editIndex = -1;
    busy = false;
    error;

    @api
    get signers() {
        return this._signers;
    }
    set signers(value) {
        this._signers = (value || []).map((s) => ({ role: s.role, name: s.name || '', email: s.email || '' }));
    }

    @api
    get previewHtml() {
        return this._previewHtml;
    }
    set previewHtml(value) {
        this._previewHtml = value;
    }

    renderedCallback() {
        const host = this.template.querySelector('.preview-body');
        if (!host) {
            this.renderedPreview = undefined;
            return;
        }
        if (this.renderedPreview !== this._previewHtml) {
            renderSafe(host, this._previewHtml);
            this.renderedPreview = this._previewHtml;
        }
    }

    // ---------- Layout ----------

    get isDesk() {
        return this.variant !== 'steps';
    }

    get isSteps() {
        return this.variant === 'steps';
    }

    get styleButtons() {
        return [
            { value: 'form', label: 'Compact form' },
            { value: 'steps', label: 'Guided steps' },
            { value: 'desk', label: 'Signing desk' }
        ].map((b) => ({ ...b, pressed: b.value === this.variant ? 'true' : 'false', cls: b.value === this.variant ? 'seg-btn on' : 'seg-btn' }));
    }

    handleStyle(event) {
        this.dispatchEvent(new CustomEvent('stylechange', { detail: { style: event.currentTarget.dataset.style } }));
    }

    handleBack() {
        this.dispatchEvent(new CustomEvent('back'));
    }

    // ---------- Steps layout ----------

    get stepItems() {
        return STEPS.map((s) => ({
            ...s,
            done: s.number < this.step,
            current: s.number === this.step ? 'step' : null,
            cls: 'stepper-item' + (s.number === this.step ? ' on' : '') + (s.number < this.step ? ' done' : '')
        }));
    }

    get onSigners() {
        return this.step === 2;
    }

    get onMessage() {
        return this.step === 3;
    }

    get onReview() {
        return this.step === 4;
    }

    get nextLabel() {
        return this.step === 2 ? 'Continue to message' : 'Continue to review';
    }

    handleStepClick(event) {
        const target = Number(event.currentTarget.dataset.step);
        if (target === 1) {
            this.handleBack();
        } else if (target < this.step) {
            this.step = target;
        }
    }

    handleNext() {
        if (this.step === 2 && this.blocked) {
            this.error = this.blockedReason;
            return;
        }
        this.error = undefined;
        this.editIndex = -1;
        this.step = Math.min(4, this.step + 1);
    }

    handlePrevious() {
        if (this.step === 2) {
            this.handleBack();
        } else {
            this.step -= 1;
        }
    }

    // ---------- Signers ----------

    get rows() {
        return this._signers.map((s, index) => {
            const colour = 's' + ((index % 6) + 1);
            return {
                ...s,
                index,
                key: index,
                num: index + 1,
                title: s.role || `Signer ${index + 1}`,
                shownName: s.name || 'No name yet',
                shownEmail: s.email || 'No email yet',
                missing: !s.email || !s.email.trim(),
                numCls: 'num ' + colour,
                editing: index === this.editIndex,
                viewing: index !== this.editIndex
            };
        });
    }

    get noSigners() {
        return this._signers.length === 0;
    }

    get severalSigners() {
        return this._signers.length > 1;
    }

    get blocked() {
        return this.noSigners || this._signers.some((s) => !s.email || !s.email.trim());
    }

    get blockedReason() {
        return this.noSigners ? 'This template has no signers. Add them under Signers in the Template Designer.' : 'Every signer needs an email address.';
    }

    get cannotSend() {
        return this.busy || this.blocked;
    }

    get orderText() {
        if (!this.severalSigners) {
            return 'One signer';
        }
        return this.together ? 'Everyone receives it at the same time' : 'Each person receives it after the one before has signed';
    }

    get sendLabel() {
        const count = this._signers.length;
        return `Send to ${count} signer${count === 1 ? '' : 's'}`;
    }

    get inSequence() {
        return !this.together;
    }

    handleEdit(event) {
        this.editIndex = Number(event.currentTarget.dataset.index);
    }

    handleDone() {
        this.editIndex = -1;
    }

    handleSigner(event) {
        const index = Number(event.target.dataset.index);
        const prop = event.target.dataset.prop;
        this._signers = this._signers.map((s, i) => (i === index ? { ...s, [prop]: event.detail.value } : s));
        this.error = undefined;
    }

    handleOrder(event) {
        this.together = event.target.value === 'together';
    }

    handleText(event) {
        this[event.target.dataset.field] = event.detail.value;
    }

    // ---------- Send ----------

    async handleSend() {
        if (this.blocked) {
            this.error = this.blockedReason;
            return;
        }
        this.busy = true;
        this.error = undefined;
        try {
            const requestId = await sendForSignature({
                templateIds: this.templateIds,
                recordId: this.recordId,
                language: this.language || null,
                providerName: this.providerName,
                // Signers who sign together all share position 1; otherwise they go in the order listed.
                signersJson: JSON.stringify(this._signers.map((s, i) => ({ role: s.role, name: s.name, email: s.email, routingOrder: this.together ? 1 : i + 1 }))),
                subject: this.subject || null,
                message: this.message || null
            });
            this.dispatchEvent(new CustomEvent('sent', { detail: { requestId } }));
        } catch (e) {
            this.error = e && e.body && e.body.message ? e.body.message : 'The document could not be sent.';
        } finally {
            this.busy = false;
        }
    }
}
