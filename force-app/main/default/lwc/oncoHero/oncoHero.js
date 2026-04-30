import { LightningElement } from 'lwc';

export default class OncoHero extends LightningElement {
    doctorImageUrl = ''; // Removed external URL to prevent CSP issues

    handleSearch(event) {
        const searchTerm = event.target.value || '';
        console.log('Search term:', searchTerm);
    }
}