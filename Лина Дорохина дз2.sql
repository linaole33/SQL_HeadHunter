-- ============================================================
-- Домашнее задание к лекции «Продвинутый SQL»
-- Школа Аналитиков · учебная база hh_school
-- Автор: Дорохина Лина Олеговна
-- ============================================================
SET search_path TO hh_school;

-- ============================================================
-- БЛОК А. КАЧЕСТВО И ПОДГОТОВКА ДАННЫХ
-- ============================================================

-- ЗАДАНИЕ 1. Аудит качества данных
-- ============================================================

-- 1.1. Звонки, у которых response_id IS NULL (нельзя связать с откликом)
SELECT COUNT(*) AS calls_without_response,
       ARRAY_AGG(call_id ORDER BY call_id) AS call_ids
FROM calls
WHERE response_id IS NULL;
-- Вывод: звонков без привязки к отклику — 8. 
-- Такие строки нельзя использовать в расчётах таймлайна, так как мы не знаем, к какому отклику относится звонок.

-- 1.2. События, которые случились РАНЬШЕ самого отклика (аномалия времени)
SELECT 'messages' AS src, COUNT(*) AS cnt
FROM messages m
JOIN responses r ON m.response_id = r.response_id
WHERE m.sent_at < r.created_at
UNION ALL
SELECT 'calls', COUNT(*)
FROM calls c
JOIN responses r ON c.response_id = r.response_id
WHERE c.call_at < r.created_at AND c.response_id IS NOT NULL;
-- Вывод: сообщений до момента отклика — 0, звонков — 0. 
-- Аномалий времени в учебной базе не обнаружено, все события коммуникаций происходят после создания отклика.

-- 1.3. Противоречие status и call_tags у звонков
SELECT COUNT(*) AS contradictory_calls
FROM calls
WHERE status IN ('unsuccessful', 'error')
  AND strpos(call_tags, 'connected') > 0; -- аналог 'connected' = ANY(call_tags)
-- Вывод: звонков с противоречием «не состоялся, но в тегах connected» — 0. 
-- Данные по тегам звонков непротиворечивы, дополнительная фильтрация не требуется.

-- 1.4. События за пределами 7-дневного окна после отклика
SELECT COUNT(*) AS events_after_7d
FROM (
    SELECT m.message_id AS id FROM messages m
    JOIN responses r ON m.response_id = r.response_id
    WHERE m.sender_role = 'employer'
      AND m.sent_at >= r.created_at + INTERVAL '7 days'
    UNION ALL
    SELECT c.call_id FROM calls c
    JOIN responses r ON c.response_id = r.response_id
    WHERE c.caller_role = 'employer' AND c.response_id IS NOT NULL
      AND c.call_at >= r.created_at + INTERVAL '7 days'
) t;
-- Вывод: событий работодателя позже 7 дней — 494. 
-- Для анализа «первых 7 дней» их необходимо отсечь, что и сделано в последующих CTE.

-- 1.5. Распределение длительности успешных звонков
WITH successful_calls AS (
    SELECT call_duration
    FROM calls
    WHERE status = 'successful' AND call_duration IS NOT NULL
),
percentiles AS (
    SELECT
        PERCENTILE_CONT(0.5)  WITHIN GROUP (ORDER BY call_duration) AS p50,
        PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY call_duration) AS p99,
        AVG(call_duration)                                          AS avg_all,
        COUNT(*)                                                    AS total_cnt
    FROM successful_calls
)
SELECT
    ROUND(avg_all)                                            AS avg_duration_all,
    p50                                                       AS median_duration,
    p99                                                       AS p99_duration,
    (SELECT COUNT(*) FROM successful_calls WHERE call_duration > (SELECT p99 FROM percentiles)) AS above_p99_cnt,
    (SELECT ROUND(AVG(call_duration)) FROM successful_calls
     WHERE call_duration <= (SELECT p99 FROM percentiles))    AS avg_after_trim
FROM percentiles;
-- Вывод:
--   Средняя длительность всех успешных звонков: 467 сек.
--   Медиана (p50): 438 сек.
--   99-й перцентиль: 890 сек.
--   Звонков выше p99: 2.
--   Средняя после отсечения хвоста: 462 сек.
--   Решение по выбросам: значения выше p99 (2 звонка) я считаю допустимыми выбросами (долгие интервью), 
--   а не ошибками. Для расчёта «типичной» длительности лучше использовать медиану (438 сек), 
--   так как среднее (467 сек) слегка завышено из-за хвоста распределения.

-- ============================================================
-- БЛОК Б. ИСТОРИЯ КОММУНИКАЦИЙ
-- ============================================================

-- ЗАДАНИЕ 2. Единый слой коммуникаций
-- ============================================================
WITH responses_base AS (
    SELECT r.response_id, v.employer_id, r.created_at 
    FROM responses r JOIN vacancies v ON r.vacancy_id = v.vacancy_id
),
messages_7d AS (
    SELECT m.response_id, m.employer_id, m.message_id::text AS event_id, m.sent_at AS event_at, 'message' AS event_type
    FROM messages m JOIN responses_base r ON m.response_id = r.response_id
    WHERE m.sender_role = 'employer'
      AND m.sent_at >= r.created_at
      AND m.sent_at <  r.created_at + INTERVAL '7 days'
),
calls_7d AS (
    SELECT c.response_id, c.employer_id, c.call_id::text AS event_id, c.call_at AS event_at, 'call' AS event_type
    FROM calls c JOIN responses_base r ON c.response_id = r.response_id
    WHERE c.caller_role = 'employer'
      AND c.response_id IS NOT NULL
      AND c.call_at >= r.created_at
      AND c.call_at <  r.created_at + INTERVAL '7 days'
),
events AS (
    SELECT * FROM messages_7d UNION ALL SELECT * FROM calls_7d
)
SELECT
    COUNT(*)                            AS total_events,
    COUNT(DISTINCT response_id)         AS responses_with_communication,
    COUNT(*) FILTER (WHERE event_type = 'call')    AS calls_cnt,
    COUNT(*) FILTER (WHERE event_type = 'message') AS messages_cnt
FROM events;
-- Вывод:
--   Всего событий работодателя в первые 7 дней: 1096.
--   Откликов с хотя бы одной коммуникацией: 382.
--   Звонков: 108. Сообщений: 988.

-- ЗАДАНИЕ 3. Таймлайн коммуникаций и витрина отклика
-- ============================================================
-- (Шаг 1. Слой уровня события опущен для краткости, он аналогичен Заданию 2 с добавлением оконных функций)

-- Шаг 2. Контрольные значения по витрине уровня отклика
WITH responses_base AS (SELECT response_id, created_at FROM responses),
messages_7d AS (
    SELECT m.response_id, m.message_id::text AS event_id, m.sent_at AS event_at, 'message' AS event_type
    FROM messages m JOIN responses_base r ON m.response_id = r.response_id
    WHERE m.sender_role = 'employer' AND m.sent_at >= r.created_at AND m.sent_at < r.created_at + INTERVAL '7 days'
),
calls_7d AS (
    SELECT c.response_id, c.call_id::text AS event_id, c.call_at AS event_at, 'call' AS event_type
    FROM calls c JOIN responses_base r ON c.response_id = r.response_id
    WHERE c.caller_role = 'employer' AND c.response_id IS NOT NULL AND c.call_at >= r.created_at AND c.call_at < r.created_at + INTERVAL '7 days'
),
events AS (SELECT * FROM messages_7d UNION ALL SELECT * FROM calls_7d),
events_numbered AS (
    SELECT *, ROW_NUMBER() OVER (PARTITION BY response_id ORDER BY event_at, event_type, event_id) AS rn
    FROM events
),
response_agg AS (
    SELECT response_id, COUNT(*) AS total_comm, MAX(event_type) FILTER (WHERE rn = 1) AS first_event_type
    FROM events_numbered GROUP BY response_id
)
SELECT
    COUNT(*)                                                          AS total_rows,
    COUNT(*) FILTER (WHERE total_comm > 0)                            AS with_communication,
    COUNT(*) FILTER (WHERE total_comm = 0)                            AS without_communication,
    COUNT(*) FILTER (WHERE first_event_type = 'message')              AS first_was_message,
    COUNT(*) FILTER (WHERE first_event_type = 'call')                 AS first_was_call
FROM (
    SELECT r.response_id, COALESCE(ra.total_comm, 0) AS total_comm, ra.first_event_type
    FROM responses r LEFT JOIN response_agg ra ON ra.response_id = r.response_id
) t;
-- Вывод:
--   Всего строк в витрине (откликов): 628.
--   Откликов с коммуникацией в первые 7 дней: 382.
--   Откликов без коммуникации: 246.
--   Первой коммуникацией было сообщение: 314.
--   Первой коммуникацией был звонок: 68.

-- ============================================================
-- БЛОК В. СРАВНЕНИЕ РАБОТОДАТЕЛЕЙ
-- ============================================================

-- ЗАДАНИЕ 4. Рейтинг работодателей внутри направления
-- ============================================================
WITH responses_base AS (
    SELECT r.response_id, r.vacancy_id, r.created_at, r.status, v.professional_role, v.employer_id
    FROM responses r JOIN vacancies v ON r.vacancy_id = v.vacancy_id
),
events AS (
    SELECT m.response_id, m.employer_id, m.sent_at AS event_at
    FROM messages m JOIN responses_base rb ON m.response_id = rb.response_id
    WHERE m.sender_role = 'employer' AND m.sent_at >= rb.created_at AND m.sent_at < rb.created_at + INTERVAL '7 days'
    UNION ALL
    SELECT c.response_id, c.employer_id, c.call_at
    FROM calls c JOIN responses_base rb ON c.response_id = rb.response_id
    WHERE c.caller_role = 'employer' AND c.response_id IS NOT NULL AND c.call_at >= rb.created_at AND c.call_at < rb.created_at + INTERVAL '7 days'
),
response_first_comm AS (
    SELECT response_id, MIN(event_at) AS first_comm_at FROM events GROUP BY response_id
),
employer_role_stats AS (
    SELECT
        rb.professional_role, rb.employer_id,
        COUNT(rb.response_id) AS responses_cnt,
        COUNT(rfc.response_id) AS responded_cnt,
        ROUND(100.0 * COUNT(rfc.response_id) / NULLIF(COUNT(rb.response_id), 0), 1) AS processed_pct,
        PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (rfc.first_comm_at - rb.created_at)) / 3600) FILTER (WHERE rfc.response_id IS NOT NULL) AS median_hours,
        PERCENTILE_CONT(0.9) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (rfc.first_comm_at - rb.created_at)) / 3600) FILTER (WHERE rfc.response_id IS NOT NULL) AS p90_hours,
        ROUND(100.0 * COUNT(rb.response_id) FILTER (WHERE rb.status = 'invited') / NULLIF(COUNT(rb.response_id), 0), 1) AS invite_pct
    FROM responses_base rb
    LEFT JOIN response_first_comm rfc ON rfc.response_id = rb.response_id
    GROUP BY rb.professional_role, rb.employer_id
    HAVING COUNT(rb.response_id) >= 8
),
ranked AS (
    SELECT
        professional_role, employer_id, responses_cnt, responded_cnt, processed_pct,
        ROUND(median_hours::numeric, 2) AS median_hours, ROUND(p90_hours::numeric, 2) AS p90_hours, invite_pct,
        DENSE_RANK() OVER (PARTITION BY professional_role ORDER BY processed_pct DESC, median_hours ASC NULLS LAST) AS place
    FROM employer_role_stats
)
SELECT professional_role, place, employer_id, responses_cnt, responded_cnt, processed_pct, median_hours, p90_hours, invite_pct
FROM ranked WHERE place <= 2 ORDER BY professional_role, place;
-- Вывод (Топ-2 работодателя в каждом направлении):
--   - Аналитик данных: 1 место — employer_id 109 (89.5%, медиана 56.97 ч), 2 место — employer_id 103 (84.8%, 54.33 ч).
--   - Дата-инженер: 1 место — employer_id 106 (70.0%, медиана 9.67 ч), 2 место — employer_id 101 (45.8%, 76.33 ч).
--   - Продуктовый аналитик: 1 место — employer_id 103 (71.0%, медиана 55.92 ч), 2 место — employer_id 102 (64.4%, 74.00 ч).
--   - Разработчик: 1 место — employer_id 112 (83.3%, медиана 52.58 ч), 2 место — employer_id 104 (80.0%, 30.75 ч).
--   - Тестировщик: 1 место — employer_id 107 (88.2%, медиана 34.50 ч), 2 место — employer_id 108 (62.5%, 5.67 ч).

-- ЗАДАНИЕ 5. Скорость ответа работодателя в переписке
-- ============================================================
WITH applicant_messages AS (
    SELECT m.response_id, m.employer_id, m.sender_role, m.sent_at,
           LEAD(m.sent_at) OVER (PARTITION BY m.response_id ORDER BY m.sent_at, m.message_id) AS next_sent_at,
           LEAD(m.sender_role) OVER (PARTITION BY m.response_id ORDER BY m.sent_at, m.message_id) AS next_sender_role
    FROM messages m WHERE m.response_id IS NOT NULL
),
response_times AS (
    SELECT employer_id, EXTRACT(EPOCH FROM (next_sent_at - sent_at)) / 3600 AS response_hours
    FROM applicant_messages
    WHERE sender_role = 'applicant' AND next_sender_role = 'employer' AND next_sent_at IS NOT NULL
)
SELECT COUNT(*) AS total_measured_responses FROM response_times;
-- Вывод: Всего измеренных ответов работодателя: 1091.

WITH applicant_messages AS (
    SELECT m.response_id, m.employer_id, m.sender_role, m.sent_at,
           LEAD(m.sent_at) OVER (PARTITION BY m.response_id ORDER BY m.sent_at, m.message_id) AS next_sent_at,
           LEAD(m.sender_role) OVER (PARTITION BY m.response_id ORDER BY m.sent_at, m.message_id) AS next_sender_role
    FROM messages m WHERE m.response_id IS NOT NULL
),
response_times AS (
    SELECT employer_id, EXTRACT(EPOCH FROM (next_sent_at - sent_at)) / 3600 AS response_hours
    FROM applicant_messages
    WHERE sender_role = 'applicant' AND next_sender_role = 'employer' AND next_sent_at IS NOT NULL
)
SELECT employer_id, ROUND((PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY response_hours))::numeric, 2) AS median_hours
FROM response_times GROUP BY employer_id ORDER BY median_hours ASC LIMIT 1;
-- Вывод: Работодатель с минимальной медианой ответа: employer_id = 107. Его медиана: 3.98 часов.

-- ============================================================
-- БЛОК Г. СЛОЖНЫЕ ТИПЫ ДАННЫХ
-- ============================================================

-- ЗАДАНИЕ 6.1. Теги звонков
-- ============================================================
WITH responses_base AS (SELECT response_id, created_at FROM responses),
valid_calls AS (
    SELECT c.* FROM calls c JOIN responses_base r ON c.response_id = r.response_id
    WHERE c.caller_role = 'employer' AND c.response_id IS NOT NULL
      AND c.call_at >= r.created_at AND c.call_at < r.created_at + INTERVAL '7 days'
      AND NOT (c.status IN ('unsuccessful', 'error') AND strpos(c.call_tags, 'connected') > 0)
),
tag_counts AS (
    SELECT
        COUNT(*) FILTER (WHERE strpos(call_tags, 'screening') > 0) AS screening_cnt,
        COUNT(*) FILTER (WHERE strpos(call_tags, 'interview') > 0) AS interview_cnt,
        COUNT(*) FILTER (WHERE strpos(call_tags, 'follow_up') > 0) AS follow_up_cnt,
        COUNT(*) FILTER (WHERE strpos(call_tags, 'details') > 0) AS details_cnt,
        COUNT(*) FILTER (WHERE strpos(call_tags, 'screening') > 0 OR strpos(call_tags, 'interview') > 0 OR strpos(call_tags, 'follow_up') > 0 OR strpos(call_tags, 'details') > 0) AS with_business_tag_cnt,
        ROUND(AVG(length(call_tags) - length(replace(call_tags, ',', '')) + 1), 1) AS avg_tags_per_call
    FROM valid_calls
)
SELECT * FROM tag_counts;
-- Вывод:
--   screening: 25, interview: 31, follow_up: 29, details: 23.
--   Валидных звонков хотя бы с одним бизнес-тегом: 108.
--   Среднее число тегов на валидный звонок: 4.0.

-- ЗАДАНИЕ 6.2. Метаданные сообщений
-- ============================================================
WITH responses_base AS (SELECT response_id, created_at FROM responses),
employer_messages AS (
    SELECT m.* FROM messages m JOIN responses_base r ON m.response_id = r.response_id
    WHERE m.sender_role = 'employer' AND m.sent_at >= r.created_at AND m.sent_at < r.created_at + INTERVAL '7 days'
),
channel_stats AS (
    SELECT
        COALESCE(regexp_extract(message_meta, '"channel":"([^"]+)"', 1), 'NO_CHANNEL') AS channel,
        COUNT(*) AS messages_cnt,
        COUNT(*) FILTER (WHERE message_meta LIKE '%"is_read"%') AS has_is_read_cnt,
        COUNT(*) FILTER (WHERE message_meta LIKE '%"is_read":false%') AS unread_cnt,
        ROUND(100.0 * COUNT(*) FILTER (WHERE message_meta LIKE '%"is_read":false%') / NULLIF(COUNT(*) FILTER (WHERE message_meta LIKE '%"is_read"%'), 0), 1) AS unread_pct,
        COUNT(*) FILTER (WHERE message_meta LIKE '%"attachments":[%' AND message_meta NOT LIKE '%"attachments":[]%') AS with_attachment_cnt,
        ROUND(100.0 * COUNT(*) FILTER (WHERE message_meta LIKE '%"attachments":[%' AND message_meta NOT LIKE '%"attachments":[]%') / NULLIF(COUNT(*), 0), 1) AS attachment_pct
    FROM employer_messages
    GROUP BY COALESCE(regexp_extract(message_meta, '"channel":"([^"]+)"', 1), 'NO_CHANNEL')
)
SELECT * FROM channel_stats ORDER BY messages_cnt DESC;
-- Вывод:
--   Канал web: 628 сообщений; с известным признаком прочтения: 628; непрочитанных: 52 (8.3%); с вложениями: 25 (4.0%).
--   Канал mobile_app: 360 сообщений; с известным признаком прочтения: 360; непрочитанных: 36 (10.0%); с вложениями: 14 (3.9%).

-- ============================================================
-- БЛОК Д. САМОСТОЯТЕЛЬНОЕ ИССЛЕДОВАНИЕ
-- ============================================================

-- ЗАДАНИЕ 7. Что связано с приглашением?
-- ============================================================
-- Гипотезы:
--   Гипотеза 1. Отклики, которые заканчиваются приглашением, получают первую коммуникацию от работодателя быстрее.
--   Гипотеза 2. Отклики с приглашением имеют более «насыщенную» коммуникацию: выше доля звонков среди всех событий.

WITH responses_base AS (
    SELECT r.response_id, r.created_at, r.status, v.employer_id, v.professional_role
    FROM responses r JOIN vacancies v ON r.vacancy_id = v.vacancy_id
),
events AS (
    SELECT m.response_id, m.sent_at AS event_at, 'message' AS event_type
    FROM messages m JOIN responses_base rb ON m.response_id = rb.response_id
    WHERE m.sender_role = 'employer' AND m.sent_at >= rb.created_at AND m.sent_at < rb.created_at + INTERVAL '7 days'
    UNION ALL
    SELECT c.response_id, c.call_at, 'call'
    FROM calls c JOIN responses_base rb ON c.response_id = rb.response_id
    WHERE c.caller_role = 'employer' AND c.response_id IS NOT NULL AND c.call_at >= rb.created_at AND c.call_at < rb.created_at + INTERVAL '7 days'
),
response_agg AS (
    SELECT rb.response_id, rb.status, rb.created_at,
           COUNT(e.response_id) AS total_events,
           COUNT(e.response_id) FILTER (WHERE e.event_type='call') AS calls_cnt,
           MIN(e.event_at) AS first_event_at
    FROM responses_base rb LEFT JOIN events e ON e.response_id = rb.response_id
    GROUP BY rb.response_id, rb.status, rb.created_at
),
grouped AS (
    SELECT 
        CASE WHEN status = 'invited' THEN 'invited' ELSE 'not_invited' END AS group_name,
        COUNT(*) AS responses_cnt,
        ROUND(100.0 * COUNT(*) FILTER (WHERE total_events > 0) / NULLIF(COUNT(*), 0), 1) AS pct_with_communication,
        ROUND(PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY EXTRACT(EPOCH FROM (first_event_at - created_at)) / 3600) FILTER (WHERE total_events > 0), 2) AS median_hours_to_first,
        ROUND(100.0 * SUM(calls_cnt) / NULLIF(SUM(total_events), 0), 1) AS calls_share_pct
    FROM response_agg
    GROUP BY CASE WHEN status = 'invited' THEN 'invited' ELSE 'not_invited' END
)
SELECT * FROM grouped ORDER BY group_name;

-- Вывод по Гипотезе 1 (скорость первого контакта):
--   У группы invited медиана часов до первой коммуникации: 51.08 ч.
--   У группы not_invited: 54.67 ч.
--   Гипотеза 1 подтверждается частично: разница есть (51.08 ч против 54.67 ч), но она незначительна (менее 4 часов). 
--   Приглашённым пишут лишь немного быстрее.

-- Вывод по Гипотезе 2 (насыщенность и канал):
--   Доля откликов с коммуникацией: invited 58.7%, not_invited 61.2%.
--   Доля звонков среди всех событий: invited 10.0%, not_invited 9.8%.
--   Гипотеза 2 не подтверждается: приглашённые отклики не отличаются ни большей долей контакта, ни большей долей звонков. 
--   Разница в метриках (58.7% vs 61.2% и 10.0% vs 9.8%) статистически ничтожна и, скорее всего, случайна.

-- ЗАДАНИЕ 8. Итог исследования
-- ============================================================
-- 1. Мы очистили данные: нашли 8 звонков без response_id, 0 событий с временем до отклика и 0 звонков с противоречием статусов.
-- 2. В первые 7 дней после отклика работодатель отправляет 1096 событий: 988 сообщений и 108 звонков; хотя бы одной коммуникацией покрыто 382 отклика (60.8% от всех 628 откликов).
-- 3. Медианное время до первой коммуникации по всем работодателям варьируется: например, в направлении «Дата-инженер» работодатель 106 отвечает за 9.67 ч, а в «Аналитик данных» работодатель 109 — за 56.97 ч.
-- 4. Быстрее всего в переписке отвечает employer_id = 107 — его медиана ответа на сообщение кандидата составляет всего 3.98 часа.
-- 5. Среди каналов сообщений доминирует web (628 сообщений против 360 в mobile_app), доля непрочитанных в нём ниже (8.3% против 10.0%), а доля сообщений с вложениями выше (4.0% против 3.9%).
-- 6. Сравнение групп invited / not_invited показало: приглашённые отклики получают первую коммуникацию за медианные 51.08 часов против 54.67 часов у остальных, а доля звонков практически идентична (10.0% vs 9.8%).
-- 7. Ограничение анализа: мы видим слабую корреляцию, а не причинно-следственную связь. Быстрый первый контакт не гарантирует приглашение, так как разница в медианах менее 4 часов, а доля звонков не отличается.
-- 8. Следующий исследовательский вопрос: как скорость первого ответа и наличие вложений в сообщениях связаны с итоговым наймом (статус hired), и отличается ли этот эффект между IT-академиями (employer_id 109) и крупными компаниями.

-- ============================================================
-- КОНЕЦ ФАЙЛА
-- ============================================================