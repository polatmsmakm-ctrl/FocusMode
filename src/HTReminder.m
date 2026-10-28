// HTReminder: a gentle local push notification if 24 hours pass without opening HelloTalk at
// all — nudges you to keep up the daily language practice. Every time the app is actually opened,
// the 24h countdown is cancelled and restarted, so the notification only ever fires on a day you
// genuinely didn't open it. Pure public UserNotifications API, nothing server-side.
#import "igd_common.h"
#import <UserNotifications/UserNotifications.h>
#define BUILD @"reminder1"
#define HT_REMINDER_ID @"ht.reminder.daily"

static void htReminderReschedule(void) {
    UNUserNotificationCenter *center = UNUserNotificationCenter.currentNotificationCenter;
    if (!raOn(@"ht.reminder")) {
        [center removePendingNotificationRequestsWithIdentifiers:@[HT_REMINDER_ID]];
        return;
    }
    [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound) completionHandler:^(BOOL granted, NSError *error) {
        if (!granted) return;
        [center removePendingNotificationRequestsWithIdentifiers:@[HT_REMINDER_ID]];
        UNMutableNotificationContent *c = [UNMutableNotificationContent new];
        c.title = @"فاتك تمرين اللغة اليوم 🗣️";
        c.body = @"ما فتحت HelloTalk اليوم — خل نكمل التعلم؟";
        c.sound = UNNotificationSound.defaultSound;
        UNTimeIntervalNotificationTrigger *trig = [UNTimeIntervalNotificationTrigger triggerWithTimeInterval:24 * 60 * 60 repeats:NO];
        UNNotificationRequest *req = [UNNotificationRequest requestWithIdentifier:HT_REMINDER_ID content:c trigger:trig];
        [center addNotificationRequest:req withCompletionHandler:nil];
    }];
}

__attribute__((constructor)) static void init(void) {
    raRegisterD(@"الفوكس", @"ht.reminder", @"تذكير يومي بالتمرين", @"إشعار لطيف لو مرّ 24 ساعة بدون ما تفتح HelloTalk", YES);
    igdRun(@"HTReminder", BUILD, ^{
        htReminderReschedule();
        [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            htReminderReschedule();
        }];
    });
}
