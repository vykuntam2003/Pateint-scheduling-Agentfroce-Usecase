import { LightningElement, api, track } from 'lwc';

export default class OncoFindDoctorInput extends LightningElement {

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
        symptomDescription: '',
        preferredCity: '',
        preferredDate: '',
        // System fields — hidden from UI but still passed through
        patientId: '',
        doctorName: ''
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