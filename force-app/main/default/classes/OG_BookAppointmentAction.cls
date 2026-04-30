/**
 * @description Agentforce Action — Book Appointment
 *              Creates a new ServiceAppointment with full validation:
 *              past-time check, patient conflict, doctor slot availability.
 * @author      Onco Global Dev Team
 * @date        2026-04-22
 */
public without sharing class OG_BookAppointmentAction {

    private static final String STATUS_SCHEDULED = 'Scheduled';
    private static final Integer DEFAULT_DURATION_MINUTES = 30;

    public class Request {
        @InvocableVariable(label='Patient Account Id' required=true)
        public String patientAccountId;
        @InvocableVariable(label='Doctor Name' description='e.g. Debashish Chatterjee' required=true)
        public String doctorName;
        @InvocableVariable(label='Facility Name')
        public String facilityName;
        @InvocableVariable(label='Work Type Name' description='e.g. Tumor Board Review')
        public String workTypeName;
        @InvocableVariable(label='Appointment Date' description='YYYY-MM-DD' required=true)
        public String appointmentDate;
        @InvocableVariable(label='Appointment Time' description='HH:MM or h:mm AM/PM' required=true)
        public String appointmentTime;
    }

    public class Response {
        @InvocableVariable(label='Is Success')
        public Boolean isSuccess;
        @InvocableVariable(label='Appointment Number')
        public String appointmentNumber;
        @InvocableVariable(label='Appointment Id')
        public String appointmentId;
        @InvocableVariable(label='Message')
        public String message;
    }

    @InvocableMethod(label='OG Book Appointment' description='Book a new appointment with validation.' category='Onco Global')
    public static List<Response> execute(List<Request> requests) {
        System.debug('OG_BookAppointmentAction invoked: ' + requests.size() + ' request(s)');
        List<Response> responses = new List<Response>();
        for (Request req : requests) {
            System.debug('Booking — Patient: ' + req.patientAccountId + ' | Doctor: ' + req.doctorName + ' | Date: ' + req.appointmentDate + ' | Time: ' + req.appointmentTime);
            responses.add(bookAppointment(req));
        }
        return responses;
    }

    private static Response bookAppointment(Request req) {
        Response res = new Response();
        res.isSuccess = false;

        Date apptDate;
        try { apptDate = Date.valueOf(req.appointmentDate); }
        catch (Exception e) { res.message = 'Invalid date. Use YYYY-MM-DD.'; System.debug('Invalid date: ' + req.appointmentDate); return res; }

        Time apptTime = parseTime(req.appointmentTime);
        if (apptTime == null) { res.message = 'Invalid time. Use HH:MM or h:mm AM/PM.'; System.debug('Invalid time: ' + req.appointmentTime); return res; }

        DateTime apptStartDT = DateTime.newInstance(apptDate, apptTime);
        System.debug('Parsed DateTime: ' + apptStartDT);

        // Validation 1: Past time
        if (apptStartDT <= DateTime.now()) {
            res.message = 'That time has already passed. Please choose a future time slot.';
            System.debug('FAIL — Past time');
            return res;
        }

        // WorkType lookup
        Integer durationMinutes = DEFAULT_DURATION_MINUTES;
        Id workTypeId = null;
        if (String.isNotBlank(req.workTypeName)) {
            String wtSearch = '%' + req.workTypeName.trim() + '%';
            List<WorkType> wTypes = [SELECT Id, Name, EstimatedDuration FROM WorkType WHERE Name LIKE :wtSearch LIMIT 1];
            if (!wTypes.isEmpty()) {
                workTypeId = wTypes[0].Id;
                if (wTypes[0].EstimatedDuration != null) durationMinutes = Integer.valueOf(wTypes[0].EstimatedDuration);
                System.debug('WorkType: ' + wTypes[0].Name + ' | Duration: ' + durationMinutes + 'min');
            }
        }
        DateTime apptEndDT = apptStartDT.addMinutes(durationMinutes);

        // Doctor → ServiceResource
        String cleanName = req.doctorName.trim().removeStartIgnoreCase('Dr.').removeStartIgnoreCase('Dr ').trim();
        String srName = 'SR_' + cleanName.replace(' ', '_');
        System.debug('Looking up SR: ' + srName);

        List<ServiceResource> resources = [SELECT Id, Name FROM ServiceResource WHERE Name = :srName AND IsActive = true LIMIT 1];
        if (resources.isEmpty()) {
            res.message = 'Could not find Dr. ' + cleanName + '. Please check the doctor name.';
            System.debug('FAIL — SR not found: ' + srName);
            return res;
        }
        ServiceResource doctorSR = resources[0];
        System.debug('SR found: ' + doctorSR.Id);

        // Territory lookup
        Id territoryId = null;
        List<ServiceTerritoryMember> stms = [
            SELECT ServiceTerritoryId, ServiceTerritory.Name, TerritoryType
            FROM ServiceTerritoryMember WHERE ServiceResourceId = :doctorSR.Id
            AND EffectiveStartDate <= :apptDate ORDER BY TerritoryType ASC LIMIT 5
        ];
        if (!stms.isEmpty()) {
            territoryId = stms[0].ServiceTerritoryId;
            System.debug('Territory: ' + stms[0].ServiceTerritory.Name);
        }

        // Validation 2: Patient conflict
        List<ServiceAppointment> conflicts = [
            SELECT Id, AppointmentNumber, SchedStartTime, SchedEndTime FROM ServiceAppointment
            WHERE ParentRecordId = :req.patientAccountId AND Status = :STATUS_SCHEDULED
            AND SchedStartTime < :apptEndDT AND SchedEndTime > :apptStartDT LIMIT 1
        ];
        if (!conflicts.isEmpty()) {
            res.message = 'You already have appointment #' + conflicts[0].AppointmentNumber
                + ' (' + conflicts[0].SchedStartTime.format('h:mm a') + '-' + conflicts[0].SchedEndTime.format('h:mm a')
                + '). Reschedule it or pick a different time?';
            System.debug('FAIL — Patient conflict: #' + conflicts[0].AppointmentNumber);
            return res;
        }
        System.debug('Validation 2 passed');

        // Validation 3: Doctor availability
        List<AssignedResource> doctorBookings = [
            SELECT ServiceAppointment.SchedStartTime FROM AssignedResource
            WHERE ServiceResourceId = :doctorSR.Id
            AND ServiceAppointment.Status NOT IN ('Canceled', 'Cannot Complete')
            AND ServiceAppointment.SchedStartTime < :apptEndDT AND ServiceAppointment.SchedEndTime > :apptStartDT LIMIT 1
        ];
        if (!doctorBookings.isEmpty()) {
            res.message = 'That time slot has just been taken. Please choose another slot.';
            System.debug('FAIL — Doctor slot taken');
            return res;
        }
        System.debug('Validation 3 passed');

        // Create appointment
        try {
            String subject = (String.isNotBlank(req.workTypeName) ? req.workTypeName.trim() : 'Appointment') + ' - with Dr. ' + cleanName;
            ServiceAppointment sa = new ServiceAppointment(
                ParentRecordId = req.patientAccountId, Subject = subject,
                SchedStartTime = apptStartDT, SchedEndTime = apptEndDT, Status = STATUS_SCHEDULED
            );
            if (workTypeId != null) sa.WorkTypeId = workTypeId;
            if (territoryId != null) sa.ServiceTerritoryId = territoryId;
            insert sa;
            System.debug('SA created: ' + sa.Id);

            insert new AssignedResource(ServiceAppointmentId = sa.Id, ServiceResourceId = doctorSR.Id);
            System.debug('AssignedResource created');

            sa = [SELECT Id, AppointmentNumber FROM ServiceAppointment WHERE Id = :sa.Id LIMIT 1];
            res.isSuccess = true;
            res.appointmentId = sa.Id;
            res.appointmentNumber = sa.AppointmentNumber;
            res.message = 'Appointment booked!\nNumber: ' + sa.AppointmentNumber
                + '\nDoctor: Dr. ' + cleanName + '\nDate: ' + apptStartDT.format('EEEE, dd MMM yyyy')
                + '\nTime: ' + apptStartDT.format('h:mm a') + '\nPlease arrive 15 minutes early.';
            System.debug('✅ SUCCESS — #' + sa.AppointmentNumber);
        } catch (Exception e) {
            res.message = 'Booking error: ' + e.getMessage();
            System.debug(LoggingLevel.ERROR, 'Error: ' + e.getMessage() + ' | ' + e.getStackTraceString());
        }
        return res;
    }

    private static Time parseTime(String timeStr) {
        if (String.isBlank(timeStr)) return null;
        try {
            String t = timeStr.trim().toUpperCase();
            Boolean isPM = t.contains('PM');
            Boolean isAM = t.contains('AM');
            t = t.replaceAll('[^0-9:]', '').trim();
            List<String> parts = t.split(':');
            Integer hour = Integer.valueOf(parts[0]);
            Integer minute = parts.size() > 1 ? Integer.valueOf(parts[1]) : 0;
            if (isPM && hour < 12) hour += 12;
            if (isAM && hour == 12) hour = 0;
            System.debug('Time parsed: "' + timeStr + '" → ' + hour + ':' + minute);
            return Time.newInstance(hour, minute, 0, 0);
        } catch (Exception e) { System.debug('Time parse failed: ' + timeStr); return null; }
    }
}