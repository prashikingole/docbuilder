import { api } from 'lwc';
import LightningModal from 'lightning/modal';

/** The Generate Document dialog in a large modal, so the options and the live preview have room. */
export default class DocBuilderGenerateModal extends LightningModal {
    @api recordId;

    handleClose() {
        this.close('closed');
    }
}
