public without sharing class OG_BookPatientApptAction {

    private static final Integer DEFAULT_DURATION = 30;
    private static final String  STATUS_SCHEDULED = 'Scheduled';

    // ── Input ────────────────────────────────────────────────────
    public class ActionInput {
        @InvocableVariable(label='Input Data' required=true)
        public InputData input;
    }

    public class InputData {
        @AuraEnabled @InvocableVariable(label='Patient Account ID' required=true
            description='Salesforce Account ID from the Identify Patient action.')
        public String patientAccountId;

        @AuraEnabled @InvocableVariable(label='Doctor Resource ID' required=true
            description='ServiceResource ID from the Find Doctors action.')
        public String doctorResourceId;

        @AuraEnabled @InvocableVariable(label='Hospital Territory ID'
            description='ServiceTerritory ID. Auto-resolved from doctor if blank.')
        public String hospitalTerritoryId;

        @AuraEnabled @InvocableVariable(label='Appointment Date and Time' required=true
            description='YYYY-MM-DD HH:MM:SS format. Must be a future date and time.')
        public String appointmentDateTime;

        @AuraEnabled @InvocableVariable(label='Appointment Type'
            description='WorkType name like New Patient Consultation. Auto-determined by agent based on symptoms.')
        public String appointmentType;

        @AuraEnabled @InvocableVariable(label='Symptom Description'
            description='The health concern described by the patient.')
        public String symptomDescription;
    }

    // ── Output ───────────────────────────────────────────────────
    public class ActionOutput {
        @InvocableVariable(label='Output Data')
        public OutputData output;
    }

    public class OutputData {
        @AuraEnabled @InvocableVariable(label='Confirmation Message'
            description='Formatted booking confirmation with all details.')
        public String confirmationMessage;

        @AuraEnabled @InvocableVariable(label='Appointment ID'
            description='ServiceAppointment record ID.')
        public String appointmentId;

        @AuraEnabled @InvocableVariable(label='Appointment Number'
            description='Human-readable appointment number.')
        public String appointmentNumber;

        @AuraEnabled @InvocableVariable(label='Doctor Name')
        public String doctorName;

        @AuraEnabled @InvocableVariable(label='Hospital Name')
        public String hospitalName;

        @AuraEnabled @InvocableVariable(label='Appointment Date')
        public String appointmentDate;

        @AuraEnabled @InvocableVariable(label='Appointment Time')
        public String appointmentTime;

        @AuraEnabled @InvocableVariable(label='Symptoms')
        public String symptoms;

        @AuraEnabled @InvocableVariable(label='Appointment Type')
        public String appointmentType;

        @AuraEnabled @InvocableVariable(label='Success'
            description='True if booked successfully.')
        public Boolean isSuccess;

        @AuraEnabled @InvocableVariable(label='Error Message'
            description='Error details if booking failed.')
        public String errorMessage;
    }

    // ── Entry Point ──────────────────────────────────────────────
    @InvocableMethod(
        label='Book Patient Appointment'
        description='Creates a ServiceAppointment and assigns the doctor. Validates slot is not in the past and checks for conflicts. Pass Patient ID, Doctor Resource ID, date/time, appointment type, and symptom description.'
        category='Onco Global')
    public static List<ActionOutput> execute(List<ActionInput> inputs) {
        InputData inp = inputs[0].input;
        OutputData outData = new OutputData();
        Savepoint sp = Database.setSavepoint();

        try {
            System.debug('>>> OG_BookPatientApptAction | patient=' + inp.patientAccountId
                + ', doctor=' + inp.doctorResourceId + ', dt=' + inp.appointmentDateTime
                + ', type=' + inp.appointmentType);

            DateTime apptStart = parseDateTime(inp.appointmentDateTime);

            // Guard 1: Past time
            if (apptStart <= DateTime.now()) {
                outData.isSuccess = false;
                outData.errorMessage = 'Cannot book in the past. Please choose a future slot.';
                ActionOutput errOut = new ActionOutput();
                errOut.output = outData;
                return new List<ActionOutput>{ errOut };
            }

            // Resolve WorkType dynamically
            WorkTypeInfo wt = resolveWorkType(inp.appointmentType);
            DateTime apptEnd = apptStart.addMinutes(wt.durationMinutes);
            System.debug('WorkType=' + wt.workTypeId + ', duration=' + wt.durationMinutes);

            // Guard 2: Doctor conflict
            if (hasConflict(inp.doctorResourceId, apptStart, apptEnd)) {
                outData.isSuccess = false;
                outData.errorMessage = 'This time slot is already booked. Please choose a different slot.';
                ActionOutput errOut = new ActionOutput();
                errOut.output = outData;
                return new List<ActionOutput>{ errOut };
            }

            // Auto-resolve territory
            System.debug('Resolving territory for doctor/input: ' + inp.hospitalTerritoryId);
            String territoryId = null;
            
            if (String.isNotBlank(inp.hospitalTerritoryId)) {
                // Check if it is already a valid ID
                try {
                    Id testId = (Id)inp.hospitalTerritoryId;
                    territoryId = testId;
                } catch (Exception e) {
                    // Not an ID, try to find by Name
                    List<ServiceTerritory> sts = [SELECT Id FROM ServiceTerritory WHERE Name = :inp.hospitalTerritoryId LIMIT 1];
                    if (!sts.isEmpty()) {
                        territoryId = sts[0].Id;
                    }
                }
            }
            
            if (String.isBlank(territoryId)) {
                territoryId = resolveTerritoryId(inp.doctorResourceId);
            }
            System.debug('Resolved Territory ID: ' + territoryId);

            // Create appointment
            ServiceAppointment appt = new ServiceAppointment(
                ParentRecordId = inp.patientAccountId,
                ServiceTerritoryId = territoryId,
                SchedStartTime = apptStart,
                SchedEndTime = apptEnd,
                Status = STATUS_SCHEDULED,
                Subject = 'Patient Appointment — '
                    + (String.isNotBlank(inp.appointmentType)
                       ? inp.appointmentType : 'General Consultation')
            );
            
            if (wt.workTypeId != null) {
                appt.WorkTypeId = wt.workTypeId;
            }
            
            // Resolve and set Doctor's Contact ID (requested to be visible in Contact field)
            Id docContactId = resolveDoctorContact(inp.doctorResourceId);
            if (docContactId != null) {
                appt.ContactId = docContactId;
            }
            
            insert appt;

            insert new AssignedResource(
                ServiceAppointmentId = appt.Id,
                ServiceResourceId = inp.doctorResourceId
            );

            // Send professional confirmation email to Patient and Doctor
            OG_EmailService.sendAppointmentEmail(appt.Id, OG_EmailService.EmailType.CONFIRMATION);

            outData = buildConfirmation(appt.Id, inp.symptomDescription);
            System.debug('Booking SUCCESS: ' + outData.appointmentNumber);

        } catch (Exception ex) {
            System.debug(LoggingLevel.ERROR, 'Error: ' + ex.getMessage()
                + ' | Stack: ' + ex.getStackTraceString());
            Database.rollback(sp);
            outData.isSuccess = false;
            outData.errorMessage = 'Booking failed: ' + ex.getMessage();
        }

        System.debug('<<< isSuccess=' + outData.isSuccess);
        ActionOutput finalOut = new ActionOutput();
        finalOut.output = outData;
        return new List<ActionOutput>{ finalOut };
    }

    // ── WorkType resolver ────────────────────────────────────────
    private class WorkTypeInfo {
        Id workTypeId;
        Integer durationMinutes;
        WorkTypeInfo(Id i, Integer d) { workTypeId = i; durationMinutes = d; }
    }

    private static WorkTypeInfo resolveWorkType(String typeName) {
        String tName = String.isNotBlank(typeName) ? typeName.trim() : 'General Consultation';
        String searchName = '%' + tName + '%';
        
        List<WorkType> wts = [SELECT Id, EstimatedDuration FROM WorkType
                               WHERE Name LIKE :searchName LIMIT 1];
        if (!wts.isEmpty()) {
            return new WorkTypeInfo(wts[0].Id, (Integer) wts[0].EstimatedDuration);
        } else {
            // Dynamically create the WorkType if it does not exist
            WorkType newWt = new WorkType(
                Name = tName,
                DurationType = 'Minutes',
                EstimatedDuration = DEFAULT_DURATION
            );
            insert newWt;
            System.debug('Dynamically created WorkType: ' + newWt.Id);
            return new WorkTypeInfo(newWt.Id, DEFAULT_DURATION);
        }
    }

    // ── Doctor Contact resolver ──────────────────────────────────
    private static Id resolveDoctorContact(String doctorResourceId) {
        try {
            ServiceResource sr = [SELECT Name FROM ServiceResource WHERE Id = :doctorResourceId LIMIT 1];
            String cleanName = sr.Name.replace('SR_', '').replace('Dr. ', '').trim();
            String[] parts = cleanName.split('[ _]');
            if (parts.size() >= 2) {
                String fName = parts[0];
                String lName = parts[1];
                List<Contact> docs = [SELECT Id FROM Contact WHERE FirstName = :fName AND LastName = :lName LIMIT 1];
                if (!docs.isEmpty()) {
                    System.debug('Resolved Doctor Contact: ' + docs[0].Id);
                    return docs[0].Id;
                }
            }
        } catch (Exception e) {
            System.debug('Could not resolve doctor contact: ' + e.getMessage());
        }
        return null;
    }

    // ── Territory resolver ───────────────────────────────────────
    private static String resolveTerritoryId(String resourceId) {
        List<ServiceTerritoryMember> ms = [
            SELECT ServiceTerritoryId FROM ServiceTerritoryMember
            WHERE ServiceResourceId = :resourceId LIMIT 1];
        return ms.isEmpty() ? null : ms[0].ServiceTerritoryId;
    }

    // ── Conflict check ───────────────────────────────────────────
    private static Boolean hasConflict(String resourceId, DateTime s, DateTime e) {
        System.debug('Checking doctor conflicts between ' + s + ' and ' + e);
        Boolean hasConflict = ![SELECT Id FROM AssignedResource
                 WHERE ServiceResourceId = :resourceId
                 AND ServiceAppointment.SchedStartTime < :e
                 AND ServiceAppointment.SchedEndTime > :s
                 AND ServiceAppointment.Status NOT IN ('Canceled', 'Cannot Complete')
                 LIMIT 1].isEmpty();
        System.debug('Doctor Conflict Found: ' + hasConflict);
        return hasConflict;
    }

    // ── Confirmation builder ─────────────────────────────────────
    private static OutputData buildConfirmation(Id apptId, String symptom) {
        ServiceAppointment a = [
            SELECT AppointmentNumber, SchedStartTime, SchedEndTime,
                   ServiceTerritory.Name, WorkType.Name,
                   (SELECT ServiceResource.Name FROM ServiceResources)
            FROM ServiceAppointment WHERE Id = :apptId];

        String doc = a.ServiceResources != null && !a.ServiceResources.isEmpty()
                   ? a.ServiceResources[0].ServiceResource.Name : 'Your Doctor';
        String hosp = a.ServiceTerritory != null ? a.ServiceTerritory.Name : 'Onco Global';
        String apptType = a.WorkType != null ? a.WorkType.Name : 'General Consultation';
        String concern = String.isNotBlank(symptom) ? symptom : 'Not specified';

        OutputData r = new OutputData();
        r.isSuccess = true;
        r.appointmentId = String.valueOf(apptId);
        r.appointmentNumber = a.AppointmentNumber;
        r.doctorName = doc;
        r.hospitalName = hosp;
        r.appointmentDate = a.SchedStartTime.format('EEEE, MMMM d, yyyy');
        r.appointmentTime = a.SchedStartTime.format('h:mm a') + ' - ' + a.SchedEndTime.format('h:mm a');
        r.symptoms = concern;
        r.appointmentType = apptType;
        
        r.confirmationMessage = String.join(new List<String>{
            'APPOINTMENT BOOKED SUCCESSFULLY',
            'Appointment # : ' + a.AppointmentNumber,
            'Doctor        : ' + doc,
            'Hospital      : ' + hosp,
            'Date          : ' + a.SchedStartTime.format('EEEE, MMMM d, yyyy'),
            'Time          : ' + a.SchedStartTime.format('h:mm a')
                              + ' - ' + a.SchedEndTime.format('h:mm a'),
            'Type          : ' + apptType,
            'Concern       : ' + concern,
            '',
            'Please arrive 15 minutes before your appointment.',
            'Bring ID proof and previous medical records.'
        }, '\n');
        return r;
    }

    // ── Email Notifications ──────────────────────────────────────
    // private static void sendNotifications(Id apptId) {
    //     try {
    //         ServiceAppointment a = [
    //             SELECT AppointmentNumber, SchedStartTime, SchedEndTime, Subject,
    //                    Contact.Email, Contact.Name,
    //                    (SELECT ServiceResource.Name, ServiceResource.RelatedRecord.Email 
    //                     FROM ServiceResources)
    //             FROM ServiceAppointment WHERE Id = :apptId LIMIT 1];

    //         List<Messaging.SingleEmailMessage> emails = new List<Messaging.SingleEmailMessage>();

    //         // 1. Email to Patient
    //         if (String.isNotBlank(a.Contact.Email)) {
    //             Messaging.SingleEmailMessage m = new Messaging.SingleEmailMessage();
    //             m.setToAddresses(new String[]{a.Contact.Email});
    //             m.setSubject('Appointment Confirmed: ' + a.AppointmentNumber);
    //             m.setHtmlBody(
    //                 '<div style="font-family: Arial, sans-serif; padding: 20px; border: 1px solid #e1e1e1; border-radius: 10px;">' +
    //                 '<h2 style="color: #0176d3;">Appointment Confirmation</h2>' +
    //                 '<p>Dear ' + a.Contact.Name + ',</p>' +
    //                 '<p>Your appointment has been successfully scheduled at <b>Onco Global SmartCare</b>.</p>' +
    //                 '<table style="width: 100%; border-collapse: collapse; margin: 20px 0;">' +
    //                 '<tr><td style="padding: 8px; color: #666;">Appointment #:</td><td style="padding: 8px;"><b>' + a.AppointmentNumber + '</b></td></tr>' +
    //                 '<tr><td style="padding: 8px; color: #666;">Date:</td><td style="padding: 8px;"><b>' + a.SchedStartTime.format('MMMM d, yyyy') + '</b></td></tr>' +
    //                 '<tr><td style="padding: 8px; color: #666;">Time:</td><td style="padding: 8px;"><b>' + a.SchedStartTime.format('h:mm a') + '</b></td></tr>' +
    //                 '</table>' +
    //                 '<p>Please arrive 15 minutes before your scheduled time.</p>' +
    //                 '<p>Thank you,<br/>Onco Global Team</p>' +
    //                 '</div>'
    //             );
    //             emails.add(m);
    //         }

    //         // 2. Email to Doctor
    //         if (!a.ServiceResources.isEmpty() && String.isNotBlank(a.ServiceResources[0].ServiceResource.RelatedRecord.Email)) {
    //             String docEmail = a.ServiceResources[0].ServiceResource.RelatedRecord.Email;
    //             Messaging.SingleEmailMessage m = new Messaging.SingleEmailMessage();
    //             m.setToAddresses(new String[]{docEmail});
    //             m.setSubject('New Appointment Scheduled: ' + a.AppointmentNumber);
    //             m.setHtmlBody(
    //                 '<div style="font-family: Arial, sans-serif; padding: 20px; border: 1px solid #e1e1e1; border-radius: 10px;">' +
    //                 '<h2 style="color: #0176d3;">New Patient Appointment</h2>' +
    //                 '<p>Hello ' + a.ServiceResources[0].ServiceResource.Name + ',</p>' +
    //                 '<p>A new appointment has been scheduled for your review.</p>' +
    //                 '<p><b>Patient:</b> ' + a.Contact.Name + '<br/>' +
    //                 '<b>Time:</b> ' + a.SchedStartTime.format('h:mm a') + ' on ' + a.SchedStartTime.format('MMMM d, yyyy') + '</p>' +
    //                 '<p>Please check your Salesforce dashboard for details.</p>' +
    //                 '</div>'
    //             );
    //             emails.add(m);
    //         }

    //         if (!emails.isEmpty()) {
    //             Messaging.sendEmail(emails);
    //             System.debug('Emails sent successfully.');
    //         }
    //     } catch (Exception e) {
    //         System.debug('Email sending failed: ' + e.getMessage());
    //     }
    // }

    // ── DateTime parser ──────────────────────────────────────────
    private static DateTime parseDateTime(String s) {
        return DateTime.valueOf(s.trim().replace('T', ' '));
    }
}