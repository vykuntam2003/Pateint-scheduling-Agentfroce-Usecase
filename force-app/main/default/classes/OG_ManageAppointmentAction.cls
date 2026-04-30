public without sharing class OG_ManageAppointmentAction {

    private static final String ACTION_RESCHEDULE = 'reschedule';
    private static final String ACTION_CANCEL     = 'cancel';
    private static final String STATUS_SCHEDULED  = 'Scheduled';
    private static final String STATUS_CANCELED   = 'Canceled';
    private static final String STATUS_DISPATCHED = 'Dispatched';

    public class Request {
        @InvocableVariable(label='Action Type' description='"reschedule" or "cancel"' required=true)
        public String actionType;
        @InvocableVariable(label='Appointment Id' required=true)
        public String appointmentId;
        @InvocableVariable(label='New Date' description='YYYY-MM-DD for reschedule')
        public String newDate;
        @InvocableVariable(label='New Time' description='HH:MM or h:mm AM/PM for reschedule')
        public String newTime;
        @InvocableVariable(label='Cancellation Reason')
        public String cancellationReason;
    }

    public class Response {
        @InvocableVariable(label='Is Success')
        public Boolean isSuccess;
        @InvocableVariable(label='Message')
        public String message;
    }

    @InvocableMethod(label='OG Manage Appointment' description='Reschedule or cancel an appointment.' category='Onco Global')
    public static List<Response> execute(List<Request> requests) {
        System.debug('OG_ManageAppointmentAction invoked: ' + requests.size() + ' request(s)');
        List<Response> responses = new List<Response>();
        for (Request req : requests) {
            System.debug('Action: ' + req.actionType + ' | Appt Id: ' + req.appointmentId);
            String action = String.isNotBlank(req.actionType) ? req.actionType.trim().toLowerCase() : '';
            if (action == ACTION_RESCHEDULE) {
                responses.add(rescheduleAppointment(req));
            } else if (action == ACTION_CANCEL) {
                responses.add(cancelAppointment(req));
            } else {
                Response res = new Response();
                res.isSuccess = false;
                res.message = 'Invalid action. Use "reschedule" or "cancel".';
                System.debug('Invalid action: ' + req.actionType);
                responses.add(res);
            }
        }
        return responses;
    }

    private static Response rescheduleAppointment(Request req) {
        Response res = new Response();
        res.isSuccess = false;

        if (String.isBlank(req.newDate) || String.isBlank(req.newTime)) {
            res.message = 'Please provide both the new date and time for rescheduling.';
            System.debug('Missing new date/time');
            return res;
        }

        Date newApptDate;
        try { newApptDate = Date.valueOf(req.newDate); }
        catch (Exception e) { res.message = 'Invalid date. Use YYYY-MM-DD.'; System.debug('Invalid date: ' + req.newDate); return res; }

        Time newApptTime = parseTime(req.newTime);
        if (newApptTime == null) { res.message = 'Invalid time. Use HH:MM or h:mm AM/PM.'; System.debug('Invalid time: ' + req.newTime); return res; }

        DateTime newStartDT = DateTime.newInstance(newApptDate, newApptTime);
        System.debug('New DateTime: ' + newStartDT);

        if (newStartDT <= DateTime.now()) {
            res.message = 'The new time has already passed. Please choose a future time slot.';
            System.debug('FAIL — Past time');
            return res;
        }

        List<ServiceAppointment> appts = [
            SELECT Id, AppointmentNumber, Subject, ParentRecordId, SchedStartTime, SchedEndTime, Status, WorkTypeId
            FROM ServiceAppointment WHERE Id = :req.appointmentId LIMIT 1
        ];
        if (appts.isEmpty()) {
            res.message = 'Appointment not found. Please check the appointment Id.';
            System.debug('Appointment not found: ' + req.appointmentId);
            return res;
        }

        ServiceAppointment sa = appts[0];
        System.debug('Found appointment #' + sa.AppointmentNumber + ' | Status: ' + sa.Status);

        if (sa.Status != STATUS_SCHEDULED && sa.Status != STATUS_DISPATCHED) {
            res.message = 'Cannot reschedule. Current status: ' + sa.Status;
            System.debug('FAIL — Non-reschedulable status: ' + sa.Status);
            return res;
        }

        Long durationMs = sa.SchedEndTime.getTime() - sa.SchedStartTime.getTime();
        Integer durationMinutes = Integer.valueOf(durationMs / 60000);
        DateTime newEndDT = newStartDT.addMinutes(durationMinutes);
        System.debug('Duration: ' + durationMinutes + 'min | New end: ' + newEndDT);

        // Patient conflict check
        List<ServiceAppointment> patientConflicts = [
            SELECT Id, AppointmentNumber, SchedStartTime FROM ServiceAppointment
            WHERE ParentRecordId = :sa.ParentRecordId AND Id != :sa.Id AND Status = :STATUS_SCHEDULED
            AND SchedStartTime < :newEndDT AND SchedEndTime > :newStartDT LIMIT 1
        ];
        if (!patientConflicts.isEmpty()) {
            res.message = 'Conflict with appointment #' + patientConflicts[0].AppointmentNumber + '. Choose a different slot.';
            System.debug('FAIL — Patient conflict: #' + patientConflicts[0].AppointmentNumber);
            return res;
        }
        System.debug('Patient conflict check passed');

        // Doctor availability check + operating hours validation
        List<AssignedResource> assignedDocs = [SELECT ServiceResourceId FROM AssignedResource WHERE ServiceAppointmentId = :sa.Id LIMIT 1];
        if (!assignedDocs.isEmpty()) {
            Id doctorSRId = assignedDocs[0].ServiceResourceId;
            System.debug('Checking doctor availability: SR Id = ' + doctorSRId);

            // Check booking conflicts
            List<AssignedResource> doctorConflicts = [
                SELECT ServiceAppointment.AppointmentNumber FROM AssignedResource
                WHERE ServiceResourceId = :doctorSRId AND ServiceAppointmentId != :sa.Id
                AND ServiceAppointment.Status NOT IN ('Canceled', 'Cannot Complete')
                AND ServiceAppointment.SchedStartTime < :newEndDT AND ServiceAppointment.SchedEndTime > :newStartDT LIMIT 1
            ];
            if (!doctorConflicts.isEmpty()) {
                res.message = 'The doctor is not available at the new time.';
                // Show available slots for this doctor on the new date
                String availSlots = getAvailableSlots(doctorSRId, newApptDate, durationMinutes, sa.Id);
                if (String.isNotBlank(availSlots)) {
                    res.message += ' Available slots on ' + newApptDate.format() + ': ' + availSlots;
                }
                System.debug('FAIL — Doctor conflict');
                return res;
            }
            System.debug('Doctor booking conflict check passed');

            // Check operating hours — is the new time within doctor's working hours?
            DateTime targetDT = DateTime.newInstance(newApptDate, Time.newInstance(0, 0, 0, 0));
            String dayOfWeek = targetDT.format('EEEE');

            List<ServiceTerritoryMember> stms = [
                SELECT OperatingHoursId FROM ServiceTerritoryMember
                WHERE ServiceResourceId = :doctorSRId AND OperatingHoursId != null
                AND EffectiveStartDate <= :newApptDate LIMIT 1
            ];

            if (!stms.isEmpty()) {
                Id ohId = stms[0].OperatingHoursId;
                List<TimeSlot> timeSlots = [
                    SELECT StartTime, EndTime FROM TimeSlot
                    WHERE OperatingHoursId = :ohId AND DayOfWeek = :dayOfWeek ORDER BY StartTime
                ];

                if (timeSlots.isEmpty()) {
                    res.message = 'The doctor does not work on ' + dayOfWeek + 's. Please choose a different date.';
                    System.debug('FAIL — Doctor not working on ' + dayOfWeek);
                    return res;
                }

                // Check if requested time falls within any slot
                Integer reqMinutes = newApptTime.hour() * 60 + newApptTime.minute();
                Boolean withinHours = false;
                for (TimeSlot ts : timeSlots) {
                    Integer slotStart = ts.StartTime.hour() * 60 + ts.StartTime.minute();
                    Integer slotEnd = ts.EndTime.hour() * 60 + ts.EndTime.minute();
                    if (reqMinutes >= slotStart && (reqMinutes + durationMinutes) <= slotEnd) {
                        withinHours = true;
                        break;
                    }
                }

                if (!withinHours) {
                    res.message = 'The requested time is outside the doctor\'s working hours.';
                    String availSlots = getAvailableSlots(doctorSRId, newApptDate, durationMinutes, sa.Id);
                    if (String.isNotBlank(availSlots)) {
                        res.message += ' Available slots on ' + newApptDate.format() + ': ' + availSlots;
                    }
                    System.debug('FAIL — Outside operating hours');
                    return res;
                }
                System.debug('Operating hours check passed');
            }
            System.debug('Doctor availability fully validated');
        }

        try {
            String oldTimeStr = sa.SchedStartTime.format('EEEE, dd MMM yyyy h:mm a');
            sa.SchedStartTime = newStartDT;
            sa.SchedEndTime = newEndDT;
            update sa;

            // Send Update Email to Patient and Doctor
            OG_EmailService.sendAppointmentEmail(sa.Id, OG_EmailService.EmailType.RESCHEDULE);

            res.isSuccess = true;
            res.message = 'Appointment #' + sa.AppointmentNumber + ' rescheduled!'
                + '\nPrevious: ' + oldTimeStr
                + '\nNew: ' + newStartDT.format('EEEE, dd MMM yyyy h:mm a')
                + '\nPlease arrive 15 minutes early.';
            System.debug('✅ Reschedule SUCCESS — #' + sa.AppointmentNumber);
        } catch (Exception e) {
            res.message = 'Reschedule error: ' + e.getMessage();
            System.debug(LoggingLevel.ERROR, 'Error: ' + e.getMessage() + ' | ' + e.getStackTraceString());
        }
        return res;
    }

    private static Response cancelAppointment(Request req) {
        Response res = new Response();
        res.isSuccess = false;

        List<ServiceAppointment> appts = [
            SELECT Id, AppointmentNumber, Subject, SchedStartTime, Status, Description
            FROM ServiceAppointment WHERE Id = :req.appointmentId LIMIT 1
        ];
        if (appts.isEmpty()) {
            res.message = 'Appointment not found. Please check the appointment Id.';
            System.debug('Appointment not found: ' + req.appointmentId);
            return res;
        }

        ServiceAppointment sa = appts[0];
        System.debug('Found appointment #' + sa.AppointmentNumber + ' | Status: ' + sa.Status);

        if (sa.Status == STATUS_CANCELED) {
            res.message = 'Appointment #' + sa.AppointmentNumber + ' is already cancelled.';
            System.debug('Already cancelled');
            return res;
        }
        if (sa.Status != STATUS_SCHEDULED && sa.Status != STATUS_DISPATCHED) {
            res.message = 'Cannot cancel. Current status: ' + sa.Status;
            System.debug('FAIL — Non-cancellable status: ' + sa.Status);
            return res;
        }

        try {
            sa.Status = STATUS_CANCELED;
            String reason = String.isNotBlank(req.cancellationReason) ? req.cancellationReason.trim() : 'Cancelled by patient via Agent';
            String existingDesc = String.isNotBlank(sa.Description) ? sa.Description + '\n' : '';
            sa.Description = existingDesc + '[Cancelled ' + DateTime.now().format('dd/MM/yyyy HH:mm') + '] Reason: ' + reason;
            update sa;

            // Send Cancellation Email to Patient and Doctor
            OG_EmailService.sendAppointmentEmail(sa.Id, OG_EmailService.EmailType.CANCELLATION);

            res.isSuccess = true;
            res.message = 'Appointment #' + sa.AppointmentNumber + ' on '
                + sa.SchedStartTime.format('dd MMM yyyy') + ' at ' + sa.SchedStartTime.format('h:mm a')
                + ' has been cancelled.\nWould you like to rebook with a different date or doctor?';
            System.debug('✅ Cancel SUCCESS — #' + sa.AppointmentNumber);
        } catch (Exception e) {
            res.message = 'Cancel error: ' + e.getMessage();
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

    // ── Get Available Slots for a Doctor ───────────────────────
    private static String getAvailableSlots(Id serviceResourceId, Date targetDate, Integer slotDuration, Id excludeApptId) {
        DateTime targetDT = DateTime.newInstance(targetDate, Time.newInstance(0, 0, 0, 0));
        String dayOfWeek = targetDT.format('EEEE');

        // Get operating hours
        List<ServiceTerritoryMember> stms = [
            SELECT OperatingHoursId FROM ServiceTerritoryMember
            WHERE ServiceResourceId = :serviceResourceId AND OperatingHoursId != null
            AND EffectiveStartDate <= :targetDate LIMIT 1
        ];
        if (stms.isEmpty()) return null;

        List<TimeSlot> timeSlots = [
            SELECT StartTime, EndTime FROM TimeSlot
            WHERE OperatingHoursId = :stms[0].OperatingHoursId AND DayOfWeek = :dayOfWeek ORDER BY StartTime
        ];
        if (timeSlots.isEmpty()) return null;

        // Get existing bookings
        DateTime dayStart = DateTime.newInstance(targetDate, Time.newInstance(0, 0, 0, 0));
        DateTime dayEnd = DateTime.newInstance(targetDate, Time.newInstance(23, 59, 59, 0));

        Set<String> bookedTimes = new Set<String>();
        for (AssignedResource ar : [
            SELECT ServiceAppointment.SchedStartTime FROM AssignedResource
            WHERE ServiceResourceId = :serviceResourceId
            AND ServiceAppointmentId != :excludeApptId
            AND ServiceAppointment.SchedStartTime >= :dayStart AND ServiceAppointment.SchedStartTime <= :dayEnd
            AND ServiceAppointment.Status NOT IN ('Canceled', 'Cannot Complete')
        ]) {
            DateTime bk = ar.ServiceAppointment.SchedStartTime;
            bookedTimes.add(formatTime(bk.hour(), bk.minute()));
        }

        // Generate available slots
        DateTime nowDT = DateTime.now();
        List<String> available = new List<String>();
        for (TimeSlot ts : timeSlots) {
            Integer startMin = ts.StartTime.hour() * 60 + ts.StartTime.minute();
            Integer endMin = ts.EndTime.hour() * 60 + ts.EndTime.minute();
            for (Integer m = startMin; m + slotDuration <= endMin; m += slotDuration) {
                Integer hr = m / 60;
                Integer mn = Math.mod(m, 60);
                String label = formatTime(hr, mn);
                if (targetDate == Date.today()) {
                    DateTime slotDT = DateTime.newInstance(targetDate, Time.newInstance(hr, mn, 0, 0));
                    if (slotDT <= nowDT) continue;
                }
                if (!bookedTimes.contains(label)) available.add(label);
            }
        }
        System.debug('Available slots for reschedule: ' + available);
        return available.isEmpty() ? null : String.join(available, ', ');
    }

    private static String formatTime(Integer hour, Integer minute) {
        String period = hour >= 12 ? 'PM' : 'AM';
        Integer displayHour = Math.mod(hour, 12);
        if (displayHour == 0) displayHour = 12;
        String minStr = minute < 10 ? '0' + minute : String.valueOf(minute);
        return displayHour + ':' + minStr + ' ' + period;
    }
}