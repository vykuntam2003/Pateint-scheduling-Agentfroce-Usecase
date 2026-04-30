import { LightningElement, api, track } from 'lwc';

export default class OncoFindDoctorOutput extends LightningElement {
    @api value;
    @api configuration; // Injected by Agentforce/Messaging runtime
    @track selectedDate = '';

    connectedCallback() {
        this.initializeDate();
    }

    initializeDate() {
        if (this.value && this.value.searchDate) {
            this.selectedDate = this.value.searchDate;
        } else {
            this.selectedDate = new Date().toISOString().split('T')[0];
        }
    }

    get isSuccess() {
        return this.value && this.value.isSuccess === true;
    }

    get parsedDoctorList() {
        if (!this.value || !this.value.doctorListJson) return [];
        try {
            return JSON.parse(this.value.doctorListJson);
        } catch (e) {
            console.error('Failed to parse doctorListJson', e);
            return [];
        }
    }

    get hasDoctors() {
        return this.parsedDoctorList.length > 0;
    }

    cleanName(rawName) {
        if (!rawName) return 'Doctor';
        return rawName.replace(/^SR_/, 'Dr. ').replace(/_/g, ' ');
    }

    cleanHospital(rawName) {
        if (!rawName) return 'Hospital';
        return rawName.replace(/_/g, ' ');
    }

    get formattedDoctorList() {
        const doctors = this.parsedDoctorList;
        if (!doctors || doctors.length === 0) return [];

        return doctors.map(doc => {
            let slotsMap = {};
            try {
                slotsMap = doc.slotsJson ? JSON.parse(doc.slotsJson) : {};
            } catch (e) { console.error('JSON Parse error', e); }

            let daySlots = slotsMap[this.selectedDate] || [];

            return {
                ...doc,
                displayName: this.cleanName(doc.name),
                displayHospital: this.cleanHospital(doc.hospitalName),
                hasSlots: daySlots.length > 0,
                slotButtons: daySlots
            };
        });
    }

    get specialtyName() {
        return this.value ? (this.value.recommendedSpecialty || '') : '';
    }

    get displayDateLabel() {
        return this.selectedDate ? `Available slots for ${this.selectedDate}` : 'Available Slots';
    }

    get errorMessage() {
        return this.value ? (this.value.errorMessage || 'Unknown error occurred.') : 'Unknown error occurred.';
    }

    handleDoctorClick(event) {
        // Prevent clicking the slot buttons from triggering the card click
        if (event.target.closest('.slot-btn')) return;
        
        const doctorName = event.currentTarget.dataset.doctor;
        const cleanDoctor = this.cleanName(doctorName);
        
        const utterance = `I want to book with ${cleanDoctor}`;
        this.submitMessage(utterance);
    }

    handleSlotClick(event) {
        event.preventDefault();
        event.stopPropagation();

        const selectedSlot = event.target.dataset.slot;
        const doctorName = event.target.dataset.doctor;
        const resourceId = event.target.dataset.resourceid;
        
        const buttons = this.template.querySelectorAll('.slot-btn');
        buttons.forEach(btn => btn.classList.remove('selected'));
        event.target.classList.add('selected');

        const cleanDoctor = this.cleanName(doctorName);
        const chatMessage = `I want to book ${cleanDoctor} at ${selectedSlot} for ${this.selectedDate}`;
        
        this.submitMessage(chatMessage);

        this.dispatchEvent(new CustomEvent('valuechange', {
            detail: { 
                value: { 
                    ...this.value, 
                    selectedSlot: selectedSlot,
                    selectedDoctor: doctorName,
                    selectedResourceId: resourceId,
                    selectedDate: this.selectedDate
                } 
            },
            bubbles: true,
            composed: true
        }));
    }

    submitMessage(text) {
        console.log('Attempting to send message:', text);
        
        // 1. Primary approach: Messaging for Web / Agentforce Utility
        if (this.configuration && this.configuration.util) {
            const util = this.configuration.util;
            const sendFn = util.sendTextMessage || util.sendMessage;
            if (sendFn) {
                sendFn.call(util, text)
                    .then(() => console.log('Message sent via util:', text))
                    .catch(err => console.error('Util send failed:', err));
                return; // Success
            }
        }

        // 2. Fallback: Custom Events for Einstein Copilot / Messaging
        const eventNames = [
            'sendmessage', 
            'sendMessage', 
            'lightning__send_message', 
            'einstein_copilot_send_message'
        ];
        
        eventNames.forEach(name => {
            this.dispatchEvent(new CustomEvent(name, {
                detail: { value: text },
                bubbles: true,
                composed: true
            }));
        });
    }
}