import { LightningElement, api } from 'lwc';

export default class OncoBookAppointmentOutput extends LightningElement {
    @api value;

    get isSuccess() {
        return this.value && this.value.isSuccess === true;
    }

    get appointmentNumber() {
        return this.value ? this.value.appointmentNumber : '';
    }

    get displayDoctor() {
        const raw = this.value ? this.value.doctorName : '';
        return raw ? raw.replace(/^SR_/, 'Dr. ').replace(/_/g, ' ') : 'N/A';
    }

    get displayHospital() {
        const raw = this.value ? this.value.hospitalName : '';
        return raw ? raw.replace(/_/g, ' ') : 'N/A';
    }

    get displayDateTime() {
        if (!this.value) return 'N/A';
        const date = this.value.appointmentDate || '';
        const time = this.value.appointmentTime || '';
        return `${date} at ${time}`;
    }

    get displayType() {
        return this.value ? this.value.appointmentType : 'N/A';
    }

    get displaySymptoms() {
        return this.value ? this.value.symptoms : 'N/A';
    }

    get errorMessage() {
        return this.value ? this.value.errorMessage : 'Unknown error occurred.';
    }
}