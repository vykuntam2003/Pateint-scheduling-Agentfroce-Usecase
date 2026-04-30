import { LightningElement, api } from 'lwc';

export default class OncoIdentifyPatientOutput extends LightningElement {
    @api value;

    get isSuccess() {
        return this.value && this.value.isSuccess === true;
    }

    get isFound() {
        return this.value && (this.value.isFound === true || this.value.isNewPatient === true);
    }

    get patientName() {
        return this.value ? this.value.patientName : '';
    }

    get message() {
        return this.value ? this.value.message : 'Unknown error occurred.';
    }
}