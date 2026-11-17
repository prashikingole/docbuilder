import { LightningElement, api } from 'lwc';
import DocBuilderGenerateModal from 'c/docBuilderGenerateModal';

/**
 * The Generate Document button. A quick action without its own screen, so it can open the dialog
 * in a large modal instead of Salesforce's fixed-width action window.
 */
export default class DocBuilderGenerateAction extends LightningElement {
    @api recordId;

    @api async invoke() {
        await DocBuilderGenerateModal.open({
            size: 'large',
            description: 'Generate a document from this record',
            recordId: this.recordId
        });
    }
}
