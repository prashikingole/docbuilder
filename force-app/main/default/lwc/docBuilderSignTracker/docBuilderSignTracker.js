import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import LightningConfirm from 'lightning/confirm';
import getSignatureView from '@salesforce/apex/DocBuilderController.getSignatureView';
import refreshSignature from '@salesforce/apex/DocBuilderController.refreshSignature';
import withdrawSignature from '@salesforce/apex/DocBuilderController.withdrawSignature';

const STATUS_TEXT = {
    Queued: 'Queued',
    Sent: 'Out for signature',
    Completed: 'Signed by everyone',
    Declined: 'Declined',
    Voided: 'Withdrawn',
    Failed: 'Could not be sent'
};

/**
 * Shows where a signature request stands. Used on the Signature Request record page and
 * inside the Generate dialog straight after sending.
 */
export default class DocBuilderSignTracker extends NavigationMixin(LightningElement) {
    _recordId;
    view;
    busy = false;
    error;

    @api
    get recordId() {
        return this._recordId;
    }
    set recordId(value) {
        this._recordId = value;
        if (value) {
            this.load();
        }
    }

    async run(work) {
        this.busy = true;
        this.error = undefined;
        try {
            this.view = await work();
        } catch (e) {
            this.error = e && e.body && e.body.message ? e.body.message : 'Something went wrong.';
        } finally {
            this.busy = false;
        }
    }

    load() {
        return this.run(() => getSignatureView({ requestId: this._recordId }));
    }

    handleCheck() {
        return this.run(() => refreshSignature({ requestId: this._recordId }));
    }

    async handleWithdraw() {
        const confirmed = await LightningConfirm.open({
            message: 'Signers will no longer be able to sign this document. This cannot be undone.',
            label: 'Withdraw this signature request?',
            theme: 'warning'
        });
        if (confirmed) {
            await this.run(() => withdrawSignature({ requestId: this._recordId, reason: 'Withdrawn by sender' }));
        }
    }

    // ---------- Display ----------

    get request() {
        return this.view ? this.view.request : null;
    }

    get status() {
        return this.request ? this.request.Status__c : '';
    }

    get statusText() {
        return STATUS_TEXT[this.status] || this.status;
    }

    get statusCls() {
        const tone = { Completed: 'good', Declined: 'bad', Failed: 'bad', Voided: 'muted' }[this.status] || 'live';
        return 'pill ' + tone;
    }

    get signers() {
        return (this.view && this.view.signers) || [];
    }

    get summary() {
        const signed = this.signers.filter((s) => s.Status__c === 'Signed').length;
        return `${signed} of ${this.signers.length} signed · sent with ${this.view.providerLabel}`;
    }

    get title() {
        return this.request && this.request.File_Name__c ? this.request.File_Name__c.replace(/\.pdf$/i, '') : 'Signature request';
    }

    get canWithdraw() {
        return this.status === 'Sent' || this.status === 'Queued';
    }

    get canCheck() {
        return this.status === 'Sent' || this.status === 'Queued';
    }

    /**
     * One line per stage: sent, each signer, then the signed copy.
     * When signers sign in sequence, only the next person is "now"; when they sign together, all waiting signers are.
     */
    get steps() {
        if (!this.request) {
            return [];
        }
        const steps = [];
        const sent = this.status !== 'Queued' && this.status !== 'Failed';
        steps.push({
            key: 'sent',
            title: this.status === 'Failed' ? 'Could not be sent' : sent ? 'Sent' : 'Waiting to be sent',
            detail: `By ${this.view.sentBy}`,
            when: sent ? this.request.Sent_On__c : null,
            state: this.status === 'Failed' ? 'bad' : sent ? 'done' : 'now'
        });

        const waiting = this.signers.filter((s) => s.Status__c !== 'Signed' && s.Status__c !== 'Declined');
        const nextOrder = waiting.length ? Math.min(...waiting.map((s) => s.Routing_Order__c || 1)) : null;
        const live = this.status === 'Sent';
        this.signers.forEach((s, index) => {
            const role = s.Role__c || `Signer ${index + 1}`;
            let state = 'todo';
            let title = `${role}, waiting`;
            if (s.Status__c === 'Signed') {
                state = 'done';
                title = `${role} signed`;
            } else if (s.Status__c === 'Declined') {
                state = 'bad';
                title = `${role} declined`;
            } else if (live && (s.Routing_Order__c || 1) === nextOrder) {
                state = 'now';
                title = `${role}, waiting to sign`;
            }
            steps.push({ key: s.Id, title, detail: `${s.Signer_Name__c || ''} · ${s.Email__c || ''}`, when: s.Signed_On__c, state });
        });

        const complete = this.status === 'Completed';
        steps.push({
            key: 'copy',
            title: complete ? 'Signed copy saved to the record' : 'Signed copy saved to the record',
            detail: complete ? '' : 'Happens automatically once everyone has signed.',
            when: complete ? this.request.Completed_On__c : null,
            state: complete ? 'done' : 'todo'
        });

        return steps.map((step, index) => ({
            ...step,
            bulletCls: 'bullet ' + step.state,
            isDone: step.state === 'done',
            isBad: step.state === 'bad',
            isOpen: step.state === 'now' || step.state === 'todo',
            titleCls: step.state === 'todo' ? 'step-title quiet' : 'step-title',
            notLast: index < steps.length - 1,
            lineCls: step.state === 'done' ? 'line done' : 'line'
        }));
    }

    get hasSent() {
        return !!(this.view && this.view.sentDocumentId);
    }

    get hasSigned() {
        return !!(this.view && this.view.signedDocumentId);
    }

    openSent() {
        this.openFile(this.view.sentDocumentId);
    }

    openSigned() {
        this.openFile(this.view.signedDocumentId);
    }

    openFile(documentId) {
        this[NavigationMixin.Navigate]({
            type: 'standard__namedPage',
            attributes: { pageName: 'filePreview' },
            state: { selectedRecordId: documentId }
        });
    }

    openSource() {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: { recordId: this.request.Record_Id__c, actionName: 'view' }
        });
    }

    get hasSource() {
        return !!(this.request && this.request.Record_Id__c);
    }
}
