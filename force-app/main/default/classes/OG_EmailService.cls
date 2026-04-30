/**
 * @description Central service for sending appointment-related emails to Patients and Doctors.
 *              Supports Creation, Update, Cancellation, and Reminders.
 */
public without sharing class OG_EmailService {

    private static final String FROM_NAME = 'Onco Global SmartCare';
    private static final String FOOTER = '\n\nRegards,\nOnco Global Patient Services\n"Precision Care for Every Life"';

    public enum EmailType { CONFIRMATION, RESCHEDULE, CANCELLATION, REMINDER }

    /**
     * @description Sends an email to the patient and doctor for a specific appointment.
     */
    public static void sendAppointmentEmail(Id apptId, EmailType type) {
        try {
            // 0. Get Org-Wide Email Address
            List<OrgWideEmailAddress> owes = [SELECT Id FROM OrgWideEmailAddress WHERE DisplayName = 'Onco Global' LIMIT 1];
            Id oweId = owes.isEmpty() ? null : owes[0].Id;

            ServiceAppointment sa = [
                SELECT Id, AppointmentNumber, SchedStartTime, SchedEndTime, Status, Subject,
                       ParentRecordId, ServiceTerritory.Name, WorkType.Name,
                       Contact.Email, Contact.Name,
                       (SELECT ServiceResource.Name, ServiceResource.RelatedRecord.Email FROM ServiceResources)
                FROM ServiceAppointment WHERE Id = :apptId LIMIT 1
            ];

            // Resolve Patient details (Person Account)
            Account patientAcc = [SELECT PersonEmail, Name FROM Account WHERE Id = :sa.ParentRecordId LIMIT 1];
            String patientEmail = patientAcc.PersonEmail;
            String patientName = patientAcc.Name;

            if (String.isBlank(patientEmail)) {
                System.debug('⚠️ No email found for patient: ' + patientName);
                return;
            }

            List<Messaging.SingleEmailMessage> emails = new List<Messaging.SingleEmailMessage>();

            // 1. Prepare Patient Email
            if (String.isNotBlank(patientEmail)) {
            emails.add(buildPatientEmail(sa, patientAcc, type, oweId));
            }

            // 2. Prepare Doctor Email
            if (!sa.ServiceResources.isEmpty() && sa.ServiceResources[0].ServiceResource.RelatedRecord != null) {
                String docEmail = sa.ServiceResources[0].ServiceResource.RelatedRecord.Email;
                if (String.isNotBlank(docEmail)) {
                    emails.add(buildDoctorEmail(sa, type, oweId, patientName));
                }
            }

            if (!emails.isEmpty()) {
                // allOrNone = false ensures that if one email fails, the others are still sent
                Messaging.sendEmail(emails, false);
                System.debug('✅ Email process completed for Appointment: ' + sa.AppointmentNumber);
            }

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, '📧 Email sending failed: ' + e.getMessage());
        }
    }

    private static Messaging.SingleEmailMessage buildPatientEmail(ServiceAppointment sa, Account patient, EmailType type, Id oweId) {
        Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
        mail.setToAddresses(new String[] { patient.PersonEmail });
        if (oweId != null) {
            mail.setOrgWideEmailAddressId(oweId);
        } else {
            mail.setSenderDisplayName(FROM_NAME);
        }
        
        String subject = '';
        String body = '';
        String doctor = !sa.ServiceResources.isEmpty() ? sa.ServiceResources[0].ServiceResource.Name : 'your specialist';
        if (doctor.startsWith('SR_')) doctor = 'Dr. ' + doctor.substring(3).replace('_', ' ');

        String dtStr = sa.SchedStartTime.format('EEEE, d MMMM yyyy, h:mm a');

        switch on type {
            when CONFIRMATION {
                subject = '✅ Confirmed: Your Appointment with ' + doctor;
                body = 'Dear ' + patient.Name + ',\n\nYour appointment at Onco Global has been successfully scheduled.\n\n' +
                       'Appointment #: ' + sa.AppointmentNumber + '\n' +
                       'Specialist: ' + doctor + '\n' +
                       'Date/Time: ' + dtStr + '\n' +
                       'Hospital: ' + sa.ServiceTerritory.Name + '\n' +
                       'Type: ' + sa.WorkType.Name +
                       '\n\nPlease arrive 15 minutes early and carry your ID proof.';
            }
            when RESCHEDULE {
                subject = '🔔 Updated: Your Appointment Details Have Changed';
                body = 'Dear ' + patient.Name + ',\n\nYour appointment details have been updated. Here is your revised schedule:\n\n' +
                       'Appointment #: ' + sa.AppointmentNumber + '\n' +
                       'Specialist: ' + doctor + '\n' +
                       'New Date/Time: ' + dtStr + '\n' +
                       'Hospital: ' + sa.ServiceTerritory.Name;
            }
            when CANCELLATION {
                subject = '❌ Cancelled: Your Appointment #' + sa.AppointmentNumber;
                body = 'Dear ' + patient.Name + ',\n\nAs per your request, your appointment with ' + doctor + ' on ' + dtStr + ' has been cancelled.\n\n' +
                       'If this was a mistake, please visit our portal or contact us to reschedule.';
            }
            when REMINDER {
                subject = '⏰ Reminder: Your Appointment is in 1 Hour';
                body = 'Dear ' + patient.Name + ',\n\nThis is a friendly reminder for your upcoming appointment today.\n\n' +
                       'Specialist: ' + doctor + '\n' +
                       'Time: ' + sa.SchedStartTime.format('h:mm a') + '\n' +
                       'Hospital: ' + sa.ServiceTerritory.Name +
                       '\n\nWe look forward to seeing you soon!';
            }
        }

        mail.setSubject(subject);
        mail.setPlainTextBody(body + FOOTER);
        return mail;
    }

    private static Messaging.SingleEmailMessage buildDoctorEmail(ServiceAppointment sa, EmailType type, Id oweId, String patientName) {
        Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
        
        String docEmail = sa.ServiceResources[0].ServiceResource.RelatedRecord.Email;
        mail.setToAddresses(new String[] { docEmail });
        if (oweId != null) {
            mail.setOrgWideEmailAddressId(oweId);
        } else {
            mail.setSenderDisplayName(FROM_NAME);
        }

        String dtStr = sa.SchedStartTime.format('h:mm a, d MMM yyyy');
        
        String subject = '';
        String body = '';

        switch on type {
            when CONFIRMATION {
                subject = 'New Appointment: ' + sa.AppointmentNumber;
                body = 'Hello,\n\nA new appointment has been scheduled with you.\n\n' +
                       'Patient: ' + patientName + '\n' +
                       'Time: ' + dtStr + '\n' +
                       'Type: ' + sa.WorkType.Name;
            }
            when RESCHEDULE {
                subject = 'Updated Appointment: ' + sa.AppointmentNumber;
                body = 'Hello,\n\nThe following appointment has been rescheduled:\n\n' +
                       'Patient: ' + patientName + '\n' +
                       'New Time: ' + dtStr;
            }
            when CANCELLATION {
                subject = 'CANCELLED: Appointment #' + sa.AppointmentNumber;
                body = 'Hello,\n\nThe appointment scheduled for ' + dtStr + ' with ' + patientName + ' has been cancelled.';
            }
            when REMINDER {
                subject = '⏰ Upcoming Patient: ' + patientName;
                body = 'Hello,\n\nYou have an upcoming appointment in 1 hour.\n\n' +
                       'Patient: ' + patientName + '\n' +
                       'Time: ' + sa.SchedStartTime.format('h:mm a');
            }
        }

        mail.setSubject(subject);
        mail.setPlainTextBody(body + FOOTER);
        return mail;
    }
}