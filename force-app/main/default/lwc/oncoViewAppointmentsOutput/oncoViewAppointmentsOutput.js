import { LightningElement, api } from 'lwc';

export default class OncoViewAppointmentsOutput extends LightningElement {
    @api value;

    get isSuccess() {
        return this.value && this.value.isSuccess === true;
    }

    get hasAppointments() {
        return this.value && this.value.hasAppointments === true;
    }

    get appointmentCount() {
        return this.value ? (this.value.appointmentCount || 0) : 0;
    }

    get appointmentSummary() {
        // Replace newline characters with <br/> for rich text display
        let text = this.value ? (this.value.appointmentSummary || '') : '';
        return text.replace(/\n/g, '<br/>');
    }

    get errorMessage() {
        return this.value ? this.value.errorMessage : 'Unknown error occurred.';
    }
}