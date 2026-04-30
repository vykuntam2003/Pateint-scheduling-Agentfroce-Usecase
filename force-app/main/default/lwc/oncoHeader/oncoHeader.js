import { LightningElement, track } from 'lwc';

export default class OncoHeader extends LightningElement {
    @track activeDropdown = null; // 'services', 'doctors', or null

    services = [
        { id: 1, name: 'Chemotherapy', desc: 'Precision medicine treatment', icon: 'utility:magicwand' },
        { id: 2, name: 'Radiation Therapy', desc: 'Advanced targeted radiation', icon: 'utility:Tower' },
        { id: 3, name: 'Surgical Oncology', desc: 'Minimally invasive surgeries', icon: 'utility:choice' },
        { id: 4, name: 'Cancer Screening', desc: 'Early detection programs', icon: 'utility:preview' }
    ];

    doctorsMenu = [
        { id: 1, name: 'Search by Specialty', desc: 'Filter specialists clinically', icon: 'utility:filterList' },
        { id: 2, name: 'Find by Hospital', desc: 'Select from 10+ campuses', icon: 'utility:location' },
        { id: 3, name: 'Top Rated Experts', desc: 'Our most awarded oncologists', icon: 'utility:favorite' },
        { id: 4, name: 'International Patients', desc: 'Medical tourism support', icon: 'utility:world' }
    ];

    get isServicesOpen() {
        return this.activeDropdown === 'services';
    }

    get isDoctorsOpen() {
        return this.activeDropdown === 'doctors';
    }

    handleToggleServices(event) {
        event.stopPropagation();
        this.activeDropdown = (this.activeDropdown === 'services') ? null : 'services';
    }

    handleToggleDoctors(event) {
        event.stopPropagation();
        this.activeDropdown = (this.activeDropdown === 'doctors') ? null : 'doctors';
    }

    // Close on any click outside (if needed)
    @track globalClickListener;
    connectedCallback() {
        this.globalClickListener = () => {
            this.activeDropdown = null;
        };
        window.addEventListener('click', this.globalClickListener);
    }

    disconnectedCallback() {
        window.removeEventListener('click', this.globalClickListener);
    }
}