import { LightningElement, api, track } from 'lwc';

export default class OncoBookAppointmentInput extends LightningElement {
    _value = {};

    @api
    get value() {
        return this._value;
    }
    set value(val) {
        this._value = val ? { ...val } : {};
        if (val) {
            this.formData = { ...this.formData, ...val };
        }
    }

    @track formData = {
        patientAccountId: '',
        doctorResourceId: '',
        hospitalTerritoryId: '',
        appointmentDateTime: '',
        appointmentType: '',
        symptomDescription: ''
    };

    handleInputChange(event) {
        const field = event.target.dataset.field;
        this.formData[field] = event.detail.value || event.target.value;
        this.dispatchValueChange();
    }

    dispatchValueChange() {
        this.dispatchEvent(new CustomEvent('valuechange', {
            detail: { value: { ...this.formData } },
            bubbles: true,
            composed: true
        }));
    }
}