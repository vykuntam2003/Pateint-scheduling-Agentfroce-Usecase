/**
 * @description Schedulable job that sends appointment reminders 1-2 hours before.
 *              Runs every hour.
 *
 *              Schedule via Developer Console:
 *              System.schedule('OG Hourly Reminder', '0 0 * * * ?', new OG_AppointmentReminderJob());
 */
public without sharing class OG_AppointmentReminderJob implements Schedulable {

    public void execute(SchedulableContext sc) {
        // Find appointments starting in the next 1 to 2 hours
        DateTime now = DateTime.now();
        DateTime windowStart = now.addHours(1);
        DateTime windowEnd = now.addHours(2);

        List<ServiceAppointment> upcoming = [
            SELECT Id FROM ServiceAppointment
            WHERE Status IN ('Scheduled', 'Dispatched')
            AND SchedStartTime >= :windowStart
            AND SchedStartTime <= :windowEnd
        ];

        for (ServiceAppointment sa : upcoming) {
            OG_EmailService.sendAppointmentEmail(sa.Id, OG_EmailService.EmailType.REMINDER);
        }
        
        System.debug('✅ OG_AppointmentReminderJob ran at ' + now + '. Sent ' + upcoming.size() + ' reminders.');
    }
}