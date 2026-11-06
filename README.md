# Proview Bookings

Restaurant reservations and table management by Proview Tech.

Live at https://bookings.proviewcrm.co.uk

Single-file app: `index.html`. Pushing to `main` redeploys via GitHub Pages.

## Proview Employee

Time tracking, attendance and time off — `employee/index.html`, served at
https://bookings.proviewcrm.co.uk/employee/

Same design system and single-file approach as Proview Bookings; data is stored in the browser (localStorage).
Includes: dashboard, clock in/out with breaks, weekly/daily timesheets, approvals, payroll hours, live locations map,
time off calendar/requests/balances, tracked-time and attendance reports with CSV export, a data assistant, shared kiosk with PINs, people/groups/roles, time tracking policies,
rounding, work schedules, holidays, locations, activities/projects/clients and organization settings.

Invoices are built but hidden for now — set `FEATURES.invoices` to `true` in `employee/index.html` to show them.
