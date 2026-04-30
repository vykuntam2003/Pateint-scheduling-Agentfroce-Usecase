import { LightningElement, api } from 'lwc';

export default class OncoUpdateAppointmentOutput extends LightningElement {
    @api value;

    get isSuccess() {
        return this.value && this.value.isSuccess === true;
    }

    get resultMessage() {
        // Replace newline characters with <br/> for rich text display
        let text = this.value ? (this.value.resultMessage || '') : '';
        return text.replace(/\n/g, '<br/>');
    }

    get errorMessage() {
        return this.value ? this.value.errorMessage : 'Unknown error occurred.';
    }
}