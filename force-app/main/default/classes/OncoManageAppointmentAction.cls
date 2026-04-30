/**
 * @class OncoManageAppointmentAction
 * @description Agentforce Action — Topic 3 (Appointment Management).
 *   action="cancel"     → guards: already-canceled, past appointment.
 *   action="reschedule" → full 4-step slot check:
 *     1. Past-time guard
 *     2. OperatingHours — does doctor work on new day?
 *     3. Working hours window — is requested time within hours?
 *     4. Booking conflict check (excluding this appointment)
 * @category Onco Global
 */
public without sharing class OncoManageAppointmentAction {

    private static final String ACTION_CANCEL     = 'cancel';
    private static final String ACTION_RESCHEDULE = 'reschedule';
    private static final String STATUS_CANCELED   = 'Canceled';
    private static final String STATUS_SCHEDULED  = 'Scheduled';

    public class ManageInput {
        @InvocableVariable(label='Appointment ID' required=true
            description='ServiceAppointment ID from the Check Existing Appointments action.')
        public String appointmentId;
        @InvocableVariable(label='Action' required=true
            description='Must be "reschedule" or "cancel".')
        public String action;
        @InvocableVariable(label='New Date and Time'
            description='Required for reschedule. Format: YYYY-MM-DD HH:MM:SS. Must be a future time.')
        public String newDateTime;
        @InvocableVariable(label='Reason'
            description='Optional reason for the cancellation or reschedule.')
        public String reason;
    }

    public class ManageResult {
        @InvocableVariable(label='Result Message'
            description='Formatted confirmation of the cancel or reschedule operation.')
        public String  resultMessage;
        @InvocableVariable(label='Success'
            description='True if the operation completed successfully.')
        public Boolean isSuccess;
        @InvocableVariable(label='Error Message'
            description='Error details if the operation failed.')
        public String  errorMessage;
    }

    @InvocableMethod(
        label='Reschedule or Cancel Appointment'
        description='Cancels or reschedules an existing appointment. For reschedule, performs full slot availability check including operating hours and booking conflicts. Pass the Appointment ID and action type.'
        category='Onco Global')
    public static List<ManageResult> manageAppointment(List<ManageInput> inputs) {
        ManageInput  inp    = inputs[0];
        ManageResult result = new ManageResult();
        try {
            System.debug('>>> OncoManageAppointmentAction.manageAppointment invoked.');
            System.debug('Input parameters: AppointmentId=' + inp.appointmentId + ', Action=' + inp.action + ', NewDateTime=' + inp.newDateTime + ', Reason=' + inp.reason);

            // ── Guard: Valid Salesforce ID format ─────────────────────
            try {
                Id validId = (Id) inp.appointmentId.trim();
            } catch (Exception e) {
                System.debug('Invalid Appointment ID format: ' + inp.appointmentId);
                result.isSuccess    = false;
                result.errorMessage = 'The value "' + inp.appointmentId
                    + '" is not a valid Appointment ID. Please use the '
                    + '"Check Existing Appointments" action first to get valid IDs.';
                return new List<ManageResult>{ result };
            }

            ServiceAppointment appt = fetchAppointment(inp.appointmentId);
            if (appt == null) {
                System.debug('Error: Appointment not found for ID: ' + inp.appointmentId);
                result.isSuccess    = false;
                result.errorMessage = 'Appointment not found. Please check the ID and try again.';
                return new List<ManageResult>{ result };
            }
            String act = String.isNotBlank(inp.action)
                ? inp.action.toLowerCase().trim() : '';
            System.debug('Resolved Action: ' + act);
             
            if      (act == ACTION_CANCEL)     result = handleCancellation(appt, inp.reason);
            else if (act == ACTION_RESCHEDULE) result = handleReschedule(appt, inp.newDateTime, inp.reason);
            else {
                System.debug('Error: Invalid action provided.');
                result.isSuccess    = false;
                result.errorMessage = 'Invalid action "' + inp.action + '". Use "cancel" or "reschedule".';
            }
        } catch (Exception ex) {
            System.debug(LoggingLevel.ERROR, 'Exception in manageAppointment: ' + ex.getMessage() + ' | Stack: ' + ex.getStackTraceString());
            result.isSuccess    = false;
            result.errorMessage = 'Error managing appointment: ' + ex.getMessage();
        }
        
        System.debug('<<< Returning result: isSuccess=' + result.isSuccess);
        return new List<ManageResult>{ result };
    }

    private static ServiceAppointment fetchAppointment(String apptId) {
        List<ServiceAppointment> rows = [
            SELECT Id, AppointmentNumber, Status, SchedStartTime, SchedEndTime,
                   AccountId, ServiceTerritoryId, WorkTypeId,
                   ServiceTerritory.Name, WorkType.Name,
                   (SELECT ServiceResource.Name, ServiceResourceId FROM ServiceResources)
            FROM ServiceAppointment WHERE Id = :apptId LIMIT 1];
        return rows.isEmpty() ? null : rows[0];
    }

    // ── Cancel handler ────────────────────────────────────────────────
    private static ManageResult handleCancellation(ServiceAppointment a, String reason) {
        System.debug('>>> Executing handleCancellation for appt: ' + a.AppointmentNumber);
        ManageResult r = new ManageResult();
        if (a.Status == STATUS_CANCELED) {
            System.debug('Error: Already canceled.');
            r.isSuccess    = false;
            r.errorMessage = 'Appointment #' + a.AppointmentNumber + ' is already canceled.';
            return r;
        }
        if (a.SchedStartTime < DateTime.now()) {
            System.debug('Error: Cannot cancel past appointment.');
            r.isSuccess    = false;
            r.errorMessage = 'Cannot cancel a past appointment (was on '
                + a.SchedStartTime.format('MMMM d, yyyy h:mm a') + ').';
            return r;
        }
        a.Status = STATUS_CANCELED;
        update a;
        System.debug('Successfully canceled appointment in database.');
        
        r.isSuccess     = true;
        r.resultMessage = buildCancelMessage(a, reason);
        return r;
    }

    // ── Reschedule handler with FULL slot availability check ──────────
    private static ManageResult handleReschedule(
            ServiceAppointment a, String newDTStr, String reason) {
        System.debug('>>> Executing handleReschedule for appt: ' + a.AppointmentNumber);
        ManageResult r = new ManageResult();
        if (String.isBlank(newDTStr)) {
            System.debug('Error: Missing newDateTime parameter.');
            r.isSuccess    = false;
            r.errorMessage = 'New date and time is required for rescheduling.';
            return r;
        }
        DateTime newStart = DateTime.valueOf(newDTStr.trim().replace('T', ' '));
        System.debug('Parsed New Start DateTime: ' + newStart);
        
        if (newStart <= DateTime.now()) {
            System.debug('Error: Cannot reschedule to past.');
            r.isSuccess    = false;
            r.errorMessage = 'Cannot reschedule to a past date and time. Please choose a future slot.';
            return r;
        }
        if (a.ServiceResources == null || a.ServiceResources.isEmpty()) {
            System.debug('Error: No doctor assigned to this appointment.');
            r.isSuccess    = false;
            r.errorMessage = 'No doctor is assigned to this appointment.';
            return r;
        }
        Id       resourceId = a.ServiceResources[0].ServiceResourceId;
        Long     durationMs = a.SchedEndTime.getTime() - a.SchedStartTime.getTime();
        DateTime newEnd     = DateTime.newInstance(newStart.getTime() + durationMs);

        // Full slot check: OperatingHours + working hours window + conflict
        System.debug('Performing slot availability check for doctor: ' + resourceId);
        SlotCheckResult check = checkSlotAvailability(resourceId, newStart, newEnd, a.Id);
        if (!check.isAvailable) {
            System.debug('Slot check failed. Reason: ' + check.reason);
            r.isSuccess    = false;
            r.errorMessage = check.reason;
            return r;
        }

        System.debug('Slot check passed. Proceeding with database update.');
        DateTime oldStart    = a.SchedStartTime;
        DateTime oldEnd      = a.SchedEndTime;
        a.SchedStartTime     = newStart;
        a.SchedEndTime       = newEnd;
        a.Status             = STATUS_SCHEDULED;
        update a;
        
        System.debug('Database update successful.');
        r.isSuccess     = true;
        r.resultMessage = buildRescheduleMessage(a, oldStart, oldEnd, newStart, newEnd, reason);
        return r;
    }

    // ── Full slot availability check (4 steps) ────────────────────────
    private class SlotCheckResult {
        Boolean isAvailable;
        String  reason;
        SlotCheckResult(Boolean ok, String msg) { isAvailable = ok; reason = msg; }
    }

    private static SlotCheckResult checkSlotAvailability(
            Id resourceId, DateTime newStart, DateTime newEnd, Id excludeApptId) {

        // Step 1: Get OperatingHours for this resource
        List<ServiceTerritoryMember> mems = [
            SELECT OperatingHoursId FROM ServiceTerritoryMember
            WHERE ServiceResourceId = :resourceId LIMIT 1];
        if (mems.isEmpty())
            return new SlotCheckResult(false,
                'Doctor schedule not configured. Please contact the hospital directly.');

        // Step 2: Get TimeSlot for the new day of week
        String newDayName = newStart.format('EEEE');
        List<TimeSlot> daySlots = [
            SELECT StartTime, EndTime FROM TimeSlot
            WHERE OperatingHoursId = :mems[0].OperatingHoursId
            AND DayOfWeek = :newDayName
            AND Type = 'Normal'
            LIMIT 1];
        if (daySlots.isEmpty())
            return new SlotCheckResult(false,
                'The doctor is not available on ' + newDayName
                + 's. Please choose a day when they practice.');

        // Step 3: Verify requested time is within working hours
        Date     newDate = newStart.date();
        DateTime ohStart = DateTime.newInstance(newDate, daySlots[0].StartTime);
        DateTime ohEnd   = DateTime.newInstance(newDate, daySlots[0].EndTime);
        if (newStart < ohStart || newEnd > ohEnd)
            return new SlotCheckResult(false,
                'The requested time is outside working hours ('
                + ohStart.format('h:mm a') + ' – ' + ohEnd.format('h:mm a')
                + '). Please choose a slot within those hours.');

        // Step 4: Booking conflict check (exclude current appointment)
        List<AssignedResource> conflicts = [
            SELECT Id FROM AssignedResource
            WHERE ServiceResourceId = :resourceId
            AND ServiceAppointment.Id != :excludeApptId
            AND ServiceAppointment.SchedStartTime < :newEnd
            AND ServiceAppointment.SchedEndTime   > :newStart
            AND ServiceAppointment.Status NOT IN ('Canceled', 'Cannot Complete')
            LIMIT 1];
        if (!conflicts.isEmpty())
            return new SlotCheckResult(false,
                'That time slot is already booked for this doctor. '
                + 'Please choose a different time.');

        return new SlotCheckResult(true, null);
    }

    // ── Message builders ──────────────────────────────────────────────
    private static String buildCancelMessage(ServiceAppointment a, String reason) {
        String doc  = a.ServiceResources != null && !a.ServiceResources.isEmpty()
                    ? a.ServiceResources[0].ServiceResource.Name : 'Not assigned';
        String hosp = a.ServiceTerritory != null ? a.ServiceTerritory.Name : 'Onco Global';
        return String.join(new List<String>{
            'APPOINTMENT CANCELED',
            'Appointment # : ' + a.AppointmentNumber,
            'Doctor        : ' + doc,
            'Hospital      : ' + hosp,
            'Was on        : ' + a.SchedStartTime.format('EEEE, MMMM d, yyyy h:mm a'),
            'Reason        : ' + (String.isNotBlank(reason) ? reason : 'Not specified'),
            '',
            'Would you like to book a new appointment?'
        }, '\n');
    }

    private static String buildRescheduleMessage(
            ServiceAppointment a, DateTime os, DateTime oe,
            DateTime ns, DateTime ne, String reason) {
        String doc  = a.ServiceResources != null && !a.ServiceResources.isEmpty()
                    ? a.ServiceResources[0].ServiceResource.Name : 'Not assigned';
        String hosp = a.ServiceTerritory != null ? a.ServiceTerritory.Name : 'Onco Global';
        return String.join(new List<String>{
            'APPOINTMENT RESCHEDULED',
            'Appointment # : ' + a.AppointmentNumber,
            'Doctor        : ' + doc,
            'Hospital      : ' + hosp,
            'Previous time : ' + os.format('EEEE, MMMM d, yyyy')
                               + ' at ' + os.format('h:mm a') + ' - ' + oe.format('h:mm a'),
            'New time      : ' + ns.format('EEEE, MMMM d, yyyy')
                               + ' at ' + ns.format('h:mm a') + ' - ' + ne.format('h:mm a'),
            'Reason        : ' + (String.isNotBlank(reason) ? reason : 'Not specified'),
            '',
            'Please arrive 15 minutes before your new appointment time.'
        }, '\n');
    }
}