import { LightningElement, track } from 'lwc';

export default class OncoDoctorFinder extends LightningElement {
    @track selectedTab = 'Medical Oncology';
    @track searchTerm = '';

    @track categories = [
        { name: 'Medical Oncology', label: 'Medical Oncology', className: 'tab-btn active' },
        { name: 'Surgical Oncology', label: 'Surgical Oncology', className: 'tab-btn' },
        { name: 'Radiation Oncology', label: 'Radiation Oncology', className: 'tab-btn' }
    ];

    @track doctors = [
        {
            id: 'd1',
            name: 'Dr. Aditi Sharma',
            degree: 'MBBS, MD',
            chamber: 'Mumbai Center',
            category: 'Medical Oncology',
            availability: ['Mon', 'Wed', 'Fri']
        },
        {
            id: 'd2',
            name: 'Dr. Rajesh Kumar',
            degree: 'MBBS, DM',
            chamber: 'Delhi Wing',
            category: 'Radiation Oncology',
            availability: ['Tue', 'Thu', 'Sat']
        },
        {
            id: 'd3',
            name: 'Dr. Priya Singh',
            degree: 'MBBS, MS',
            chamber: 'Bangalore Clinic',
            category: 'Surgical Oncology',
            availability: ['Mon', 'Tue', 'Thu']
        },
        {
            id: 'd4',
            name: 'Dr. Sunil Patel',
            degree: 'MBBS, MD',
            chamber: 'Hyderabad Lab',
            category: 'Medical Oncology',
            availability: ['Wed', 'Fri', 'Sun']
        },
        {
            id: 'd5',
            name: 'Dr. Meera Joshi',
            degree: 'MBBS, MD',
            chamber: 'Chennai Unit',
            category: 'Medical Oncology',
            availability: ['Mon', 'Thu', 'Fri']
        }
    ];

    get filteredDoctors() {
        return this.doctors.filter(doc => {
            const matchesTab = doc.category === this.selectedTab;
            const matchesSearch = doc.name.toLowerCase().includes(this.searchTerm.toLowerCase()) ||
                doc.degree.toLowerCase().includes(this.searchTerm.toLowerCase());
            return matchesTab && matchesSearch;
        });
    }

    handleTabClick(event) {
        this.selectedTab = event.target.dataset.tab;
        this.categories = this.categories.map(tab => ({
            ...tab,
            className: tab.name === this.selectedTab ? 'tab-btn active' : 'tab-btn'
        }));
    }

    handleSearch(event) {
        this.searchTerm = event.target.value;
    }

    handleBook(event) {
        const doctorName = event.target.dataset.doctor;
        const chatMessage = `I'd like to book an appointment with ${doctorName}`;
        
        console.log('Booking:', chatMessage);
        
        // Dispatch multiple event names for compatibility
        const eventNames = ['sendmessage', 'sendMessage', 'lightning__send_message'];
        eventNames.forEach(name => {
            this.dispatchEvent(new CustomEvent(name, {
                detail: { value: chatMessage },
                bubbles: true,
                composed: true
            }));
        });
    }
}