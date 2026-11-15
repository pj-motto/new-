# Database migration order

For an existing installation through 060, apply only 061 through 067 in the
order below. Existing migration files were not edited by this upgrade.

For a fresh Supabase database, 000 is a read-only inspection. Supabase supplies
the `auth` and `storage` schemas. Enable `pg_trgm` before 011:

```sql
create extension if not exists pg_trgm;
```

Before 043, the owner account configured in that file must already exist in
Supabase Auth and have a profile. Create/sign up that account first. The migration
intentionally refuses to proceed otherwise. Read its configured email locally;
do not substitute another person's account without intending to make it the owner.

There are two DIFFERENT files numbered 045. Run both: one is the one-hour
escalation feature and one is the Super Admin improvements feature. 047 repeats
and clarifies the one-hour escalation definitions from `045_one_hour_lgu_escalation.sql`.
It is the later authoritative version; retain it and apply it after 046. These
are overlapping migrations, not byte-identical files. Do not delete or renumber
either 045 file or 047. Later 051 also refines the escalation workflow.

The exact ordered inventory is:

1. `migrations/000_inspect_current_schema.sql` — read only
2. `migrations/001_align_core_tables.sql`
3. `migrations/002_report_workflow.sql`
4. `migrations/003_notifications_audit.sql`
5. `migrations/004_rls_policies.sql`
6. `migrations/005_storage_bucket.sql`
7. `migrations/006_auth_profile_and_roles.sql`
8. `migrations/007_report_rpcs.sql`
9. `migrations/008_analytics_views.sql`
10. `migrations/009_hardening.sql`
11. `migrations/010_hazard_types.sql`
12. `migrations/011_relief_assistance.sql`
13. `migrations/012_road_works.sql`
14. `migrations/013_faqs.sql`
15. `migrations/014_preparedness_guides.sql`
16. `migrations/015_urgent_alert_acks.sql`
17. `migrations/016_sos_log.sql`
18. `migrations/017_road_status.sql`
19. `migrations/018_others_review.sql`
20. `migrations/019_beneficiaries_privacy.sql`
21. `migrations/020_report_barangay_pick.sql`
22. `migrations/021_allow_backend_profile_changes.sql`
23. `migrations/022_auto_verify_on_report.sql`
24. `migrations/023_reports_feed_is_mine.sql`
25. `migrations/024_analytics_invoker.sql`
26. `migrations/025_corroboration_radius.sql`
27. `migrations/026_scope_reads_by_barangay.sql`
28. `migrations/027_report_edit_guard.sql`
29. `migrations/028_status_flow.sql`
30. `migrations/029_barangay_scoping.sql`
31. `migrations/030_barangay_routing.sql`
32. `migrations/031_road_status_full.sql`
33. `migrations/032_guides_v2.sql`
34. `migrations/033_audit_coverage.sql`
35. `migrations/034_dispatch_details.sql`
36. `migrations/035_rename_tanod_to_response_team.sql`
37. `migrations/036_escalation_policy.sql`
38. `migrations/037_fix_evacuation_read_policy.sql`
39. `migrations/038_dispatch_units.sql`
40. `migrations/039_dispatch_report_v2.sql`
41. `migrations/040_dispatch_rpcs.sql`
42. `migrations/041_core_modules_def_settings.sql`
43. `migrations/042_dispatch_units_dedup.sql`
44. `migrations/043_super_admin.sql`
45. `migrations/044_reports_documentation.sql`
46. `migrations/045_one_hour_lgu_escalation.sql`
47. `migrations/045_super_admin_improvements.sql`
48. `migrations/046_super_admin_verify_block_and_change_requests.sql`
49. `migrations/047_one_hour_lgu_escalation.sql`
50. `migrations/048_fixpack_01.sql`
51. `migrations/049_dispatch_team_features.sql`
52. `migrations/050_equipment_management.sql`
53. `migrations/051_report_workflow_fixes.sql`
54. `migrations/052_reroute_and_advisory_seed.sql`
55. `migrations/053_barangay_boundaries.sql`
56. `migrations/054_equipment_categories.sql`
57. `migrations/055_equipment_catalogs_and_check_fix.sql`
58. `migrations/056_realtime_core_tables.sql`
59. `migrations/057_auto_dispatch_tracking_ratings_sos.sql`
60. `migrations/058_role_ratings.sql`
61. `migrations/059_rating_handlers.sql`
62. `migrations/060_sos_barangay_and_default_dispatch.sql`
63. `migrations/061_notifications_core.sql`
64. `migrations/062_push_pipeline.sql`
65. `migrations/063_dispatch_alarm_ack.sql`
66. `migrations/064_watchdog_jobs.sql`
67. `migrations/065_alert_settings.sql`
68. `migrations/066_notification_coverage.sql`
69. `migrations/067_dispatch_live_tracking.sql`
