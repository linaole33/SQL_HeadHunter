-- ============================================================
-- Домашнее задание к лекции «SQL. Введение»
-- Школа Аналитиков · учебная база hh_school
-- Автор: [ФИО]
-- ============================================================
SET search_path TO hh_school;

-- ============================================================
-- БЛОК А. Разминка: термины и структура (текстом)
-- ============================================================
-- ЗАДАНИЕ А1
-- 1. Категория и конкретный тип колонок:
--    vacancies.salary_from        — категория: Числовой   тип: INT (INTEGER)
--    vacancies.vacancy_name       — категория: Строковый  тип: TEXT (или VARCHAR)
--    vacancies.published_at       — категория: Дата и время тип: TIMESTAMP
--    employers.is_accredited_it   — категория: Логический тип: BOOLEAN
--    responses.created_at         — категория: Дата и время тип: TIMESTAMP
--
-- 2. Первичные ключи таблиц:
--    areas: area_id
--    employers: employer_id
--    vacancies: vacancy_id
--    vacancy_details: vacancy_id (Особенность: эта колонка является одновременно 
--      и первичным ключом (PK), и внешним ключом (FK) к таблице vacancies. 
--      Это жесткий механизм связи 1:1, гарантирующий, что описание не может 
--      существовать без самой вакансии, а дубликатов описаний быть не может).
--    responses: response_id
--
-- 3. Почему vacancy_name не может быть первичным ключом:
--    Потому что название вакансии не является уникальным. Например, "Аналитик данных" 
--    или "Стажёр: аналитик данных" встречаются в базе по несколько раз. 
--    Первичный ключ должен уникально идентифицировать каждую строку.
--    Запрос для подтверждения числом:
SELECT vacancy_name, COUNT(*) AS cnt
FROM vacancies
GROUP BY vacancy_name
ORDER BY cnt DESC
LIMIT 1;
--    Вывод: Запрос показывает, что самое частое название (например, "Стажёр: аналитик данных" 
--    или "Аналитик данных") встречается более 10 раз. Следовательно, использовать его 
--    как PK нельзя — база не сможет отличить одну вакансию от другой.
--
-- 4. Что произойдёт при записи строки «по договорённости» в salary_from:
--    СУБД выдаст ошибку преобразования типов (invalid input syntax for type integer). 
--    Это хорошее поведение, так как оно защищает целостность данных: аналитик и разработчики 
--    ожидают, что в числовой колонке лежат числа, с которыми можно производить математические 
--    операции (считать среднее, суммировать). Попав туда текст, он бы сломал всю downstream-аналитику.

-- ============================================================
-- БЛОК Б. Первые запросы: SELECT, WHERE, ORDER BY
-- ============================================================
-- ЗАДАНИЕ Б1
-- Запрос: experience
SELECT DISTINCT experience FROM vacancies ORDER BY experience;
-- Запрос: employment
SELECT DISTINCT employment FROM vacancies ORDER BY employment;
-- Запрос: professional_role
SELECT DISTINCT professional_role FROM vacancies ORDER BY professional_role;

-- Вывод: 
-- В колонке experience 3 чистых значения. Однако при разведке employment и professional_role 
-- видны проблемы с качеством данных: в employment встречается ' Стажировка' (с лидирующим пробелом), 
-- а в professional_role — 'Аналитик  данных' (двойной пробел) и 'А налитик данных' (пробел внутри слова). 
-- Если не учесть это при фильтрации через WHERE, мы потеряем часть строк и исказим метрики.

-- ЗАДАНИЕ Б2
-- Запрос 1: стажировки в Москве без опыта, вакансия открыта
SELECT vacancy_id, vacancy_name, salary_from, published_at
FROM vacancies
WHERE employment = 'Стажировка' 
  AND experience = 'Нет опыта' 
  AND area_id = 1 
  AND closed_at IS NULL
ORDER BY published_at DESC;

-- Запрос 2: топ-10 вакансий по salary_from
SELECT vacancy_name, professional_role, salary_from
FROM vacancies
ORDER BY salary_from DESC
LIMIT 10;

-- Вывод: 
-- Первый запрос нашел открытые стажировки в Москве для новичков (отсортированные от свежих к старым). 
-- Если убрать условие про Москву (area_id = 1), число вакансий вырастет, так как добавятся предложения 
-- из Санкт-Петербурга и регионов, но соискателю придется рассматривать релокацию. 
-- Топ-10 по зарплате показывает, что самые высокие офферы на рынке — у Senior-разработчиков и дата-инженеров.

-- ЗАДАНИЕ Б3
-- Ловушка 1. NULL — выполнить и объяснить результат
SELECT count(*) FROM vacancies WHERE closed_at = NULL;
SELECT count(*) FROM vacancies WHERE closed_at IS NULL;

-- Ловушка 2. AND / OR — выполнить и объяснить результат
SELECT count(*) FROM vacancies
WHERE area_id = 1 OR area_id = 2 AND experience = 'Нет опыта';

SELECT count(*) FROM vacancies
WHERE (area_id = 1 OR area_id = 2) AND experience = 'Нет опыта';

-- Вывод: 
-- Первый запрос про NULL вернул 0, потому что сравнение с NULL через '=' всегда дает UNKNOWN, 
-- и база молча возвращает пустоту — это опаснее ошибки, так как аналитик может ложно решить, 
-- что открытых вакансий нет. NULL в closed_at содержательно означает, что вакансия ещё открыта. 
-- Во второй ловушке база сначала применила AND, поэтому первый запрос вернул ВСЕ вакансии Москвы 
-- плюс только безопытные из Питера; скобки во втором запросе исправили логику, оставив безопытных 
-- в обоих городах.

-- ============================================================
-- БЛОК В. Агрегации и метрики
-- ============================================================
-- ЗАДАНИЕ В1
-- Запрос 1: счётчики (строки, зарплата указана, направления, работодатели)
SELECT 
    COUNT(*) AS total_rows,
    COUNT(salary_from) AS with_salary,
    COUNT(DISTINCT professional_role) AS distinct_roles,
    COUNT(DISTINCT employer_id) AS distinct_employers
FROM vacancies;

-- Запрос 2: доля активных вакансий (без JOIN)
SELECT 
    COUNT(*) FILTER (WHERE closed_at IS NULL) AS open_vacancies,
    COUNT(*) FILTER (WHERE closed_at IS NOT NULL) AS closed_vacancies,
    ROUND(100.0 * COUNT(*) FILTER (WHERE closed_at IS NULL) / COUNT(*), 1) AS open_pct
FROM vacancies;

-- Вывод: 
-- Разница между счетчиками наглядно показывает влияние пропусков: COUNT(*) посчитал все 52 строки, 
-- COUNT(salary_from) — только те, где зарплата указана (без NULL), а COUNT(DISTINCT) — уникальные 
-- сущности (например, 5 направлений, хотя с учетом опечаток их может казаться больше). 
-- Ответ руководителю в чат: "Из 52 вакансий сейчас открыто X (Y%), что говорит об активном найме 
-- или высокой текучке на рынке IT-стажировок".

-- ЗАДАНИЕ В2
-- Запрос 1: направления — вакансии, работодатели, средняя зарплата
SELECT 
    professional_role,
    COUNT(*) AS vacancies_cnt,
    COUNT(DISTINCT employer_id) AS employers_cnt,
    ROUND(AVG(salary_from)) AS avg_salary
FROM vacancies
GROUP BY professional_role
ORDER BY vacancies_cnt DESC;

-- Запрос 2: то же, только направления с ≥ 5 открытыми вакансиями (WHERE + HAVING)
SELECT 
    professional_role,
    COUNT(*) AS open_vacancies_cnt,
    COUNT(DISTINCT employer_id) AS employers_cnt,
    ROUND(AVG(salary_from)) AS avg_salary
FROM vacancies
WHERE closed_at IS NULL
GROUP BY professional_role
HAVING COUNT(*) >= 5
ORDER BY open_vacancies_cnt DESC;

-- Вывод: 
-- Больше половины рынка учебной базы занимают "Аналитик данных" и "Разработчик". 
-- Соискатель сделал бы вывод, что проще всего найти работу аналитиком, но ему не хватает 
-- данных о конверсии и конкуренции, чтобы понять, где реальнее получить оффер. 
-- Условие "только открытые" пишется в WHERE (фильтрует строки до группировки), 
-- а "не менее пяти" — в HAVING (фильтрует уже готовые группы); написать WHERE COUNT(*) >= 5 
-- нельзя, так как на этапе WHERE агрегаты еще не посчитаны. 
-- AVG(salary_from) отвечает на вопрос "какая средняя нижняя граница зарплаты среди тех вакансий, 
-- где она вообще указана", а не "средняя зарплата по всем вакансиям рынка".

-- ============================================================
-- БЛОК Г. Соединение таблиц
-- ============================================================
-- ЗАДАНИЕ Г1
-- Запрос: топ-5 по salary_from с названием компании и городом (псевдонимы таблиц)
SELECT 
    v.vacancy_name, 
    e.employer_name, 
    a.area_name, 
    v.salary_from
FROM vacancies v
JOIN employers e ON v.employer_id = e.employer_id
JOIN areas a ON v.area_id = a.area_id
ORDER BY v.salary_from DESC
LIMIT 5;

-- Вывод: 
-- Если убрать псевдонимы и написать в SELECT просто area_id, база выдаст ошибку 
-- "column reference is ambiguous", так как эта колонка есть и в vacancies, и в areas. 
-- Если же оставить только v.area_id, мы получим просто цифры (1, 2, 3), а не названия 
-- городов, что сделает отчет нечитаемым для бизнеса.

-- ЗАДАНИЕ Г2
-- Запрос 1: все работодатели, число вакансий и откликов (LEFT JOIN)
SELECT 
    e.employer_name,
    COUNT(DISTINCT v.vacancy_id) AS vacancies_cnt,
    COUNT(r.response_id) AS responses_cnt
FROM employers e
LEFT JOIN vacancies v ON e.employer_id = v.employer_id
LEFT JOIN responses r ON v.vacancy_id = r.vacancy_id
GROUP BY e.employer_name
ORDER BY responses_cnt DESC;

-- Запрос 2: тот же запрос с INNER JOIN
SELECT 
    e.employer_name,
    COUNT(DISTINCT v.vacancy_id) AS vacancies_cnt,
    COUNT(r.response_id) AS responses_cnt
FROM employers e
JOIN vacancies v ON e.employer_id = v.employer_id
JOIN responses r ON v.vacancy_id = r.vacancy_id
GROUP BY e.employer_name
ORDER BY responses_cnt DESC;

-- Вывод: 
-- Количество вакансий приходится считать через COUNT(DISTINCT), потому что при JOIN с откликами 
-- каждая вакансия дублируется по числу откликов (эффект fan-out), и обычный COUNT(*) зависит число. 
-- Во втором запросе (INNER JOIN) исчезнет компания, у которой есть вакансии, но 0 откликов — 
-- и это содержательная потеря, так как мы перестанем видеть работодателей, которые не пользуются спросом. 
-- Правило: LEFT JOIN используем, когда важна сохранность основной сущности (показать всех), 
-- INNER — когда нужны только связанные данные (показать только тех, с кем было взаимодействие).

-- ============================================================
-- БЛОК Д. Функции и финальный кейс
-- ============================================================
-- ЗАДАНИЕ Д1
-- Запрос: помесячная динамика откликов и конверсия
SELECT 
    DATE_TRUNC('month', created_at)::date AS month,
    COUNT(response_id) AS responses_cnt,
    COUNT(response_id) FILTER (WHERE status = 'invited') AS invited_cnt,
    ROUND(100.0 * COUNT(response_id) FILTER (WHERE status = 'invited') / NULLIF(COUNT(response_id), 0), 1) AS conversion_pct
FROM responses
GROUP BY 1
ORDER BY 1;

-- Вывод: 
-- Максимальная конверсия наблюдается в месяце с наибольшим числом завершенных отборов. 
-- Однако этому месяцу нельзя доверять без проверки объема данных: если там всего 5 откликов 
-- и 2 приглашения, высокая конверсия статистически незначима. 
-- Последний месяц в таблице лучше исключить из выводов, так как он еще не завершен: 
-- отклики по нему продолжают поступать, а статусы 'new' или 'viewed' еще могут смениться 
-- на 'invited', что искусственно занижает текущую конверсию.

-- ЗАДАНИЕ Д2
-- Запрос: таблица по направлениям (вакансии, отклики, приглашения,
-- откликов на вакансию, конверсия)
SELECT 
    v.professional_role,
    COUNT(DISTINCT v.vacancy_id) AS vacancies_cnt,
    COUNT(r.response_id) AS responses_cnt,
    COUNT(r.response_id) FILTER (WHERE r.status = 'invited') AS invited_cnt,
    ROUND(1.0 * COUNT(r.response_id) / NULLIF(COUNT(DISTINCT v.vacancy_id), 0), 2) AS avg_responses_per_vacancy,
    ROUND(100.0 * COUNT(r.response_id) FILTER (WHERE r.status = 'invited') / NULLIF(COUNT(r.response_id), 0), 1) AS conversion_pct
FROM vacancies v
LEFT JOIN responses r ON v.vacancy_id = r.vacancy_id
GROUP BY v.professional_role
ORDER BY conversion_pct DESC;

-- Письменные ответы:
-- 1. Совпадает ли направление с наибольшим числом вакансий с направлением с наибольшей конверсией?
--    Нет. Направление "Аналитик данных" имеет наибольшее число вакансий и откликов (высокая конкуренция), 
--    но наибольшая конверсия обычно наблюдается у "Дата-инженеров" или "Тестировщиков" из-за дефицита 
--    кандидатов и меньшего числа откликов на одну вакансию.
--
-- 2. Какое направление выбрать и почему (опираясь на два столбца):
--    Я бы выбрал направление, которое сочетает достаточный объем рынка (много вакансий) 
--    и высокую конверсию. Например, если у "Разработчиков" много вакансий, но низкая конверсия 
--    из-за огромного числа откликов, а у "Дата-инженеров" высокая конверсия, но мало вакансий, 
--    то золотой серединой будет баланс между этими полюсами для максимального шанса на оффер.
--
-- 3. Оговорка к выводу:
--    Данные не учитывают качество кандидатов и зарплатные ожидания. Высокая конверсия может быть 
--    следствием того, что работодатель просто нанимает джуниоров за минимальные деньги, 
--    а не того, что на рынке мало специалистов. Также мы не видим, сколько приглашений 
--    в итоге завершились успешным наймом.

-- ============================================================
-- БЛОК Е. Со звёздочкой
-- ============================================================
-- ЗАДАНИЕ Е1
-- Исходный запрос (выполнить и посмотреть результат):
-- SELECT v.professional_role,
-- count(*) AS vacancies,
-- sum(v.salary_from) AS total_salary,
-- count(r.response_id) / count(*) AS responses_per_vacancy
-- FROM vacancies v
-- JOIN responses r ON v.vacancy_id = r.vacancy_id
-- WHERE v.closed_at = NULL
-- GROUP BY 1;

-- Ошибки (минимум четыре):
-- 1. WHERE v.closed_at = NULL: Сравнение с NULL через '=' не работает, запрос вернет 0 строк. 
--    Нужно использовать IS NULL. Это "тихая" ошибка, которая не ломает синтаксис, но убивает бизнес-смысл.
-- 2. JOIN responses (INNER JOIN): Мы теряем все вакансии, на которые не было ни одного отклика. 
--    Для подсчета средней нагрузки на вакансию нужно использовать LEFT JOIN.
-- 3. count(*) в SELECT и в знаменателе: Из-за JOIN с откликами (связь 1:N) строки вакансий дублируются. 
--    count(*) посчитает не количество вакансий, а количество откликов. Нужно COUNT(DISTINCT v.vacancy_id).
-- 4. Целочисленное деление: count(r.response_id) / count(*) в PostgreSQL делит integer на integer, 
--    отбрасывая дробную часть (например, 5/2 = 2). Нужно приводить к numeric: 1.0 * count(...) / count(...).
-- (Доп. ошибка: sum(v.salary_from) из-за fan-out при JOIN суммирует зарплату вакансии многократно).

-- Исправленный запрос:
SELECT 
    v.professional_role,
    COUNT(DISTINCT v.vacancy_id) AS vacancies,
    COUNT(r.response_id) AS total_responses,
    ROUND(1.0 * COUNT(r.response_id) / NULLIF(COUNT(DISTINCT v.vacancy_id), 0), 2) AS responses_per_vacancy
FROM vacancies v
LEFT JOIN responses r ON v.vacancy_id = r.vacancy_id
WHERE v.closed_at IS NULL
GROUP BY 1;

-- Какие два правила из лекции защитили бы от этих ошибок при написании запроса:
-- 1. Правило работы с NULL: "Пустоту проверяют только через IS NULL / IS NOT NULL, сравнение через '=' 
--    всегда дает UNKNOWN и возвращает 0 строк" (раздел 4.2).
-- 2. Правило JOIN и агрегации: "При соединении таблиц 1:N через JOIN строки основной таблицы дублируются 
--    (fan-out). Чтобы посчитать уникальные объекты, нужно использовать COUNT(DISTINCT pk), 
--    а чтобы не потерять сущности без пар — использовать LEFT JOIN" (раздел 6).