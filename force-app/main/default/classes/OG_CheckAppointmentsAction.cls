/**
 * @description Agentforce Action — Check Existing Appointments
 *              Retrieves a patient's upcoming or recent appointments
 *              with doctor, location, and work type details.
 * @author      Onco Global Dev Team
 * @date        2026-04-22
 */
public without sharing class OG_CheckAppointmentsAction {

    private static final Set<String> ACTIVE_STATUSES = new Set<String>{'Scheduled', 'Dispatched'};
    private static final String STATUS_COMPLETED = 'Completed';
    private static final String STATUS_CANCELED  = 'Canceled';

    public class Request {
        @InvocableVariable(label='Patient Account Id' description='The Account Id of the patient' required=true)
        public String patientAccountId;
        @InvocableVariable(label='Include Past' description='Set to true to include past/completed appointments')
        public Boolean includePast;
    }

    public class Response {
        @InvocableVariable(label='Appointments List' description='Formatted list of appointments')
        public String appointmentsList;
        @InvocableVariable(label='Has Upcoming' description='True if patient has upcoming appointments')
        public Boolean hasUpcoming;
        @InvocableVariable(label='Appointment Count' description='Number of appointments found')
        public Integer appointmentCount;
        @InvocableVariable(label='Message' description='Status message')
        public String message;
    }

    @InvocableMethod(label='OG Check Appointments' description='Check a patient upcoming and past appointments.' category='Onco Global')
    public static List<Response> execute(List<Request> requests) {
        System.debug('OG_CheckAppointmentsAction invoked with ' + requests.size() + ' request(s)');
        List<Response> responses = new List<Response>();
        for (Request req : requests) {
            System.debug('Checking appointments for Patient Account: ' + req.patientAccountId + ' | Include Past: ' + req.includePast);
            responses.add(checkAppointments(req));
        }
        return responses;
    }

    private static Response checkAppointments(Request req) {
        Response res = new Response();
        res.hasUpcoming = false;
        res.appointmentCount = 0;

        if (String.isBlank(req.patientAccountId)) {
            res.message = 'Patient Account Id is required to check appointments.';
            System.debug('Missing patientAccountId');
            return res;
        }

        List<ServiceAppointment> appointments;
        DateTime nowDT = DateTime.now();

        if (req.includePast == true) {
            appointments = [
                SELECT Id, AppointmentNumber, Subject, Status,
                       SchedStartTime, SchedEndTime,
                       ServiceTerritory.Name, ServiceTerritory.City,
                       WorkType.Name
                FROM ServiceAppointment
                WHERE ParentRecordId = :req.patientAccountId
                ORDER BY SchedStartTime DESC
                LIMIT 20
            ];
            System.debug('Queried all appointments (with past) → ' + appointments.size() + ' result(s)');
        } else {
            appointments = [
                SELECT Id, AppointmentNumber, Subject, Status,
                       SchedStartTime, SchedEndTime,
                       ServiceTerritory.Name, ServiceTerritory.City,
                       WorkType.Name
                FROM ServiceAppointment
                WHERE ParentRecordId = :req.patientAccountId
                AND Status IN :ACTIVE_STATUSES
                AND SchedStartTime >= :nowDT
                ORDER BY SchedStartTime ASC
                LIMIT 20
            ];
            System.debug('Queried upcoming appointments → ' + appointments.size() + ' result(s)');
        }

        if (appointments.isEmpty()) {
            res.message = 'You have no upcoming appointments. Would you like to book one?';
            res.appointmentsList = '';
            System.debug('No appointments found for patient');
            return res;
        }

        // Bulk query: Get assigned doctors
        Set<Id> apptIds = new Set<Id>();
        for (ServiceAppointment sa : appointments) {
            apptIds.add(sa.Id);
        }

        Map<Id, String> apptToDoctorName = new Map<Id, String>();
        for (AssignedResource ar : [
            SELECT ServiceAppointmentId, ServiceResource.Name
            FROM AssignedResource
            WHERE ServiceAppointmentId IN :apptIds
        ]) {
            String srName = ar.ServiceResource.Name;
            String doctorName = srName;
            if (srName != null && srName.startsWith('SR_')) {
                doctorName = 'Dr. ' + srName.substring(3).replace('_', ' ');
            }
            apptToDoctorName.put(ar.ServiceAppointmentId, doctorName);
        }
        System.debug('Loaded doctor names for ' + apptToDoctorName.size() + ' appointment(s)');

        // Build formatted output
        List<String> lines = new List<String>();
        Integer upcomingCount = 0;

        for (ServiceAppointment sa : appointments) {
            Boolean isUpcoming = sa.SchedStartTime >= nowDT && ACTIVE_STATUSES.contains(sa.Status);
            if (isUpcoming) upcomingCount++;

            String doctor = apptToDoctorName.containsKey(sa.Id)
                ? apptToDoctorName.get(sa.Id) : 'Unassigned';

            String statusIcon = '';
            if (sa.Status == STATUS_COMPLETED) statusIcon = '✅ ';
            else if (sa.Status == STATUS_CANCELED) statusIcon = '❌ ';
            else if (isUpcoming) statusIcon = '📅 ';

            String territory = sa.ServiceTerritory != null ? sa.ServiceTerritory.Name : '';
            if (territory.startsWith('ST_')) {
                territory = territory.substring(3).replace('_', ' ');
            }

            String entry = statusIcon + 'Appointment #' + sa.AppointmentNumber;
            entry += '\n   Doctor: ' + doctor;
            entry += '\n   Date: ' + sa.SchedStartTime.format('EEEE, dd MMM yyyy');
            entry += '\n   Time: ' + sa.SchedStartTime.format('h:mm a') + ' - ' + sa.SchedEndTime.format('h:mm a');
            if (String.isNotBlank(territory)) entry += '\n   Location: ' + territory;
            if (sa.WorkType != null) entry += '\n   Type: ' + sa.WorkType.Name;
            entry += '\n   Status: ' + sa.Status;
            entry += '\n   Appointment Id: ' + sa.Id;
            lines.add(entry);

            System.debug('  → #' + sa.AppointmentNumber + ' | ' + doctor + ' | ' + sa.SchedStartTime.format('dd/MM/yyyy HH:mm') + ' | ' + sa.Status);
        }

        res.appointmentsList = String.join(lines, '\n\n');
        res.appointmentCount = appointments.size();
        res.hasUpcoming = upcomingCount > 0;

        if (upcomingCount > 0) {
            res.message = 'You have ' + upcomingCount + ' upcoming appointment(s). Would you like to book a new appointment, or reschedule/cancel an existing one?';
        } else {
            res.message = 'No upcoming appointments found.';
            if (req.includePast == true && !appointments.isEmpty()) {
                res.message += ' Showing ' + appointments.size() + ' past appointment(s).';
            }
        }
        System.debug('✅ Check complete — ' + upcomingCount + ' upcoming, ' + appointments.size() + ' total');
        return res;
    }
}