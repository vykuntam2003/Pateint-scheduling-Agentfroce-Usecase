import { LightningElement, track } from 'lwc';

export default class OncoSpecialtyGrid extends LightningElement {
    @track specialties = [
        {
            id: 's1',
            title: 'Medical Oncology',
            description: 'Chemotherapy, targeted therapy, immunotherapy.',
            icon: '🧪',
            class: 'icon-wrap medical'
        },
        {
            id: 's2',
            title: 'Radiation Oncology',
            description: 'Advanced radiation treatment options.',
            icon: '⚡️',
            class: 'icon-wrap radiation'
        },
        {
            id: 's3',
            title: 'Surgical Oncology',
            description: 'Minimally invasive and robotic surgeries.',
            icon: '🔪',
            class: 'icon-wrap surgical'
        },
        {
            id: 's4',
            title: 'Gynecologic Oncology',
            description: 'Women’s cancer care and fertility preservation.',
            icon: '♀️',
            class: 'icon-wrap medical'
        },
        {
            id: 's5',
            title: 'Pediatric Oncology',
            description: 'Specialized care for children with cancer.',
            icon: '👶',
            class: 'icon-wrap surgical'
        }
    ];
}