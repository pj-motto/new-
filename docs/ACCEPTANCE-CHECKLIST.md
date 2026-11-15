# Live installation acceptance checklist

These checks require your deployed Supabase project, valid VAPID configuration,
a controlled test, and actual devices. They were not executed against production.
The prompt's referenced section 10 was missing; the checks below supplement the
included automated regressions.

Use separate test accounts: citizen in barangay A, official in A, official in B,
ordinary LGU, Super Admin, and two members of the same dispatch unit. Tell the
people receiving trial alerts that this is a test. Use test SOS notes that clearly
say TEST. Keep your normal emergency phone/radio procedure available.

| Check | Expected result |
| --- | --- |
| Sign in/restore each receiving role | Enrollment is visible when alerts are off; sound unlock appears for responders |
| iPhone installed PWA | Home Screen instructions are accurate; a test push arrives after permission is granted |
| Send self-test as a citizen or unit member | Only that account's registered devices receive it |
| Submit SOS in A | LGU and A ring; B and other citizens do not. Citizen sender sees confirmation |
| Super Admin default backstop | Silent pending card initially; siren when server escalation arrives |
| Super Admin Every SOS setting | Immediate SOS siren; ordinary LGU cannot change this setting |
| Leave an SOS before signing in | Pending SOS rings after session restore without waiting for a new item |
| Keep a form dirty/dropdown open | New SOS body overlay/banner and siren still start |
| Several simultaneous SOS | One SOS siren; every pending card visible; new SOS reopens a minimised overlay |
| Mark SOS read / mark all read | Unread dots may clear; pending card, banner and siren remain |
| Mute normal hazard alarms | SOS and unit dispatch sirens continue |
| Minimise overlay | Banner and siren remain; Open restores it |
| Deny acknowledgement with network off | Clear failure; pending item and alarm remain; retry on reconnect |
| Acknowledge from another allowed device | All devices stop promptly through Realtime; with a broken socket, the 15-second visible-page recovery poll catches up |
| Wrong barangay attempts SOS acknowledgement | Server rejects it |
| Unit receives dispatch | Members' devices ring until a person acknowledges; unrelated units do not |
| Unit shares first GPS fix/moves | GPS can set acknowledged/en_route; it never sets human alarm acceptance |
| One unit member acknowledges | The unit's other devices stop ringing; person/time are recorded |
| Unit declines with a reason | Existing decline/reassignment workflow runs; pending unit alarm closes |
| Reporter receives en-route/on-scene updates | Inbox and push; help chime on an open unlocked page |
| Unacknowledged SOS at timeout | One escalation per SOS, including Super Admin; job timing has up to one minute of scheduling delay |
| Acknowledged SOS with no arrival | One urgent no-arrival notification; arrival/resolution closes it |
| Report stays unverified for one hour | LGU and correct barangay receive one pinned escalation |
| New report and change request | Correct inboxes/push; Super Admin request opens existing review modal |
| Shelter Full/Closed, road status, relief phase, low stock, equipment condition | Appropriate scoped notifications; no repeated low-stock alerts while continuously below the threshold |
| Notification with no supported detail route | Expanded notification content is shown instead of a dead tap |
| Quiet hours at 22:00–06:00 Manila | Normal/info honor prefs; critical/urgent responder items and own SOS/emergency advisory exceptions bypass them |
| Advisory with in-app delivery | Inbox only; push advisory generates one delivery path rather than browser + server duplicates |
| Remove device and sign out on a shared browser | Old account stops receiving push on that browser; next account can enroll |
| Reload offline with confirmed pending SOS | Last confirmed pending state remains and requests a siren after audio unlock; reconciliation corrects it when online |
| Live tracking access | LGU/Super Admin see allowed units; official sees own barangay. No verify/dispatch controls added to Super Admin tracking |
| Stationary and moving unit | Fresh fixes are requested every 15 seconds while app runs; stale fixes are not refreshed into fake current timestamps |
| Poor GPS accuracy | Marker shows accuracy; a fix worse than 150 m cannot confirm arrival |
| Arrival radius change | Only Super Admin changes the setting; next accurate fix uses it |
| Signal silence and recovery | Amber/lost state, one lost-signal alert per outage, all copies auto-ack on a fresh fix |
| Tracking drawer and SOS detail | Ordered receipt, named acknowledgement, automatic GPS events and resolution timeline |
| Closed app / locked phone / low battery | Record actual device limitations; continuous background GPS and siren are not guaranteed |
| SMS without provider | Function logs would-send count; no SMS delivery is claimed |
| SMS with configured provider | Test provider delivery/credit and request format before relying on it |

Long-duration audio validation: after 30 minutes the siren should become a short
once-per-minute reminder. Never use the three-second Settings test to infer the
phone's closed-app, silent-mode, low-power or background behavior.

A Realtime disconnect can lengthen acknowledgement propagation beyond two
seconds. The app reconciles on reconnect, focus, visibility return and its
15-second visible-page poll. An open dirty form does not block those queries.
